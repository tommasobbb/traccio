import SwiftUI
import TraccioCore

/// "Anticipi" — every movement the user marked as money laid out for others,
/// in one place: the total still owed, a per-person roll-up ("chi ti deve
/// quanto"), and the list of advances with a lifecycle-status filter.
/// Reached from the "Altro" tab (ADR 0009; moved there from Impostazioni by
/// `docs/decisions/0033-more-tab-and-settings-corner.md`).
///
/// No mockup covers this screen (`docs/design/canvas/` has no Anticipi
/// artboard), so it follows `EventsView`'s shape: `Card`s in a `ScrollView`,
/// pushed (no `NavigationStack` of its own), empty state as explanatory text
/// inside a card rather than a full-screen `EmptyState`.
///
/// Every figure shown is server-derived (`domain/advances.py`, ADR 0026) —
/// the view renders `AdvancesViewModel.Loaded`, it never sums anything. An
/// advance write on the pushed `TransactionDetailView` bumps
/// `DataFreshness.Scope.dashboard`, which this screen keys its reload to.
struct AdvancesView: View {
    @Environment(DataFreshness.self) private var freshness
    @State private var model: AdvancesViewModel
    private let client: any APIClientProtocol
    /// Shared between a person/advance row and its pushed detail screen so
    /// the push zooms from the row's own frame instead of sliding in
    /// (`docs/decisions/0030-liquid-glass-chrome.md`). One namespace for
    /// both lists — a person id and an advance id never collide (both real
    /// UUIDs from unrelated sequences).
    @Namespace private var transitionNamespace

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend; also handed to
    ///     `TransactionDetailView` so both screens share one client instance.
    init(client: any APIClientProtocol = APIClient.current) {
        self.client = client
        _model = State(wrappedValue: AdvancesViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            content
                .padding(Spacing.gutter)
        }
        .screenChrome("Anticipi")
        .animation(.easeInOut(duration: 0.2), value: model.state.tag)
        .refreshable { await model.load() }
        .task(id: freshness.token(for: .dashboard)) { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ListSkeleton()
        case .loaded(let loaded):
            loadedContent(loaded)
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare gli anticipi",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.load() } }
            )
        }
    }

    @ViewBuilder
    private func loadedContent(_ loaded: AdvancesViewModel.Loaded) -> some View {
        let summary = loaded.response.summary
        if loaded.response.advances.isEmpty, summary.byPerson.isEmpty, summary.totals.isEmpty,
            model.statusFilter == nil
        {
            emptyCard
        } else {
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                if !summary.totals.isEmpty {
                    totalsCard(summary.totals)
                }
                if !summary.byPerson.isEmpty {
                    peopleCard(
                        summary.byPerson,
                        loaded: loaded,
                        showsGapNote: loaded.hasUnattributedReimbursements
                    )
                }
                advancesCard(loaded)
            }
        }
    }

    /// The only empty card in the app with no way forward from itself
    /// (`EventsView.emptyCard` ends in a `PillButton`) — an advance has no
    /// standalone creation flow, it only ever starts from a transaction row's
    /// own action, so the pointer names that gesture instead of offering a
    /// button this screen can't back.
    private var emptyCard: some View {
        Card {
            EyebrowLabel(text: "Anticipi")
            Text(
                "Quando paghi qualcosa per altri, segna quel movimento come anticipo dal suo dettaglio: qui vedrai chi ti deve dei soldi e quanto ti manca di rientrare."
            )
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
            Divider().overlay(Palette.separatorSubtle)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tightGap) {
                Image(systemName: "arrow.turn.right.up")
                    .font(.system(size: 12, weight: .semibold))
                (Text("Vai su Movimenti, apri un movimento e scegli ")
                    + Text("Segna come anticipo").fontWeight(.semibold))
                    .font(Typography.caption)
            }
            .foregroundStyle(Palette.inkTertiary)
        }
    }

    // MARK: - Summary

    /// The screen's `.raised` protagonist — the only one on the screen, same
    /// as the dashboard hero and `PersonDetailView`'s own summary card, whose
    /// anatomy (figure, `ProgressBar`, Atteso/Rientrato pair) this copies
    /// rather than reinventing (2026-09-19: this card, and the two lists
    /// below it, used to be flat text with no figure worth registering at a
    /// glance — exactly the anatomy the drill-down one tap away already had).
    private func totalsCard(_ totals: [ReceivableTotalResponse]) -> some View {
        Card(elevation: .raised) {
            EyebrowLabel(text: "Da ricevere")
            ForEach(totals) { total in
                totalBlock(total)
                if total.id != totals.last?.id {
                    Divider().overlay(Palette.separator)
                }
            }
        }
    }

    /// One currency's block — the typical case is a single currency, so this
    /// is almost always the entire card's body. Unlike `PersonDetailView`'s
    /// equivalent, there's no "Saldato" branch for a zero figure: this is an
    /// aggregate across every advance in the currency, and a zero total here
    /// doesn't mean there's nothing left to look at below (some may still be
    /// open in another currency, or the count is simply zero for now).
    private func totalBlock(_ total: ReceivableTotalResponse) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cardSectionGap) {
            AmountText(
                amount: total.outstanding,
                currencyCode: total.currency,
                kind: .income,
                font: Typography.heroFigure
            )
            ProgressBar(fraction: total.reimbursedFraction)
            HStack {
                advanceFigureColumn(label: "Atteso", amount: total.expected, currency: total.currency)
                Spacer()
                advanceFigureColumn(
                    label: "Rientrato", amount: total.reimbursed, currency: total.currency
                )
            }
            Text(countLabel(total.openAdvances, one: "anticipo aperto", many: "anticipi aperti"))
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private func peopleCard(
        _ people: [PersonSummaryResponse], loaded: AdvancesViewModel.Loaded, showsGapNote: Bool
    ) -> some View {
        Card {
            EyebrowLabel(text: "Chi ti deve")
            VStack(spacing: 0) {
                ForEach(people) { person in
                    NavigationLink {
                        PersonDetailView(
                            person: person,
                            advances: loaded.advances(
                                forPersonKey: person.personKey, currency: person.currency
                            ),
                            client: client,
                            onNeedsReload: { Task { await model.load() } },
                            onDashboardStale: { freshness.markStale([.dashboard, .transactions]) }
                        )
                        #if os(iOS)
                        .navigationTransition(.zoom(sourceID: person.id, in: transitionNamespace))
                        #endif
                    } label: {
                        personRow(person)
                    }
                    .buttonStyle(.pressableRow)
                    .matchedTransitionSource(id: person.id, in: transitionNamespace)
                    if person.id != people.last?.id {
                        Divider().overlay(Palette.separator)
                    }
                }
            }
            if showsGapNote {
                Text(
                    "Alcuni rimborsi non sono assegnati a una persona, quindi il totale può superare la somma qui sopra."
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    /// Leading `InitialsAvatar` plus a narrow `ProgressBar` under the name —
    /// this and `advanceRow` below used to be the only rows in the app with
    /// no leading element at all (2026-09-19).
    private func personRow(_ person: PersonSummaryResponse) -> some View {
        HStack(spacing: Spacing.itemGap) {
            InitialsAvatar(name: person.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ProgressBar(fraction: person.reimbursedFraction, height: 4)
                        .frame(width: 64)
                    Text(countLabel(person.advanceCount, one: "anticipo", many: "anticipi"))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if person.outstanding == 0 {
                Badge(text: "Saldato", style: .neutral)
            } else {
                AmountText(
                    amount: person.outstanding,
                    currencyCode: person.currency,
                    kind: .income
                )
            }
            DisclosureChevron()
        }
        .padding(.vertical, Spacing.rowPadding)
        .contentShape(Rectangle())
        .rowScrollTransition()
    }

    // MARK: - Advances list

    private func advancesCard(_ loaded: AdvancesViewModel.Loaded) -> some View {
        Card {
            HStack {
                EyebrowLabel(text: "Anticipi")
                Spacer()
                statusMenu
            }
            if loaded.response.advances.isEmpty {
                Text(
                    model.statusFilter == nil
                        ? "Non hai ancora segnato nessun movimento come anticipo."
                        : "Nessun anticipo in questo stato."
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(loaded.response.advances) { advance in
                        advanceRowLink(advance)
                        if advance.id != loaded.response.advances.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
        }
    }

    private var statusMenu: some View {
        Menu {
            Button("Tutti") { Task { await model.setStatusFilter(nil) } }
            Button("Aperti") { Task { await model.setStatusFilter(.open) } }
            Button("Saldati") { Task { await model.setStatusFilter(.settled) } }
            Button("Stralciati") { Task { await model.setStatusFilter(.writtenOff) } }
        } label: {
            FilterChip(
                title: Self.filterLabel(model.statusFilter),
                isActive: model.statusFilter != nil,
                trailingSystemImage: "chevron.down"
            )
        }
    }

    private func advanceRowLink(_ advance: AdvanceResponse) -> some View {
        NavigationLink {
            TransactionDetailLoader(
                transactionID: advance.transactionID,
                advance: advance,
                client: client,
                onUpdate: { _ in Task { await model.load() } },
                onAdvanceChange: { _ in Task { await model.load() } },
                onDashboardStale: { freshness.markStale([.dashboard, .transactions]) }
            )
            #if os(iOS)
            .navigationTransition(.zoom(sourceID: advance.id, in: transitionNamespace))
            #endif
        } label: {
            advanceRow(advance)
        }
        .buttonStyle(.pressableRow)
        .matchedTransitionSource(id: advance.id, in: transitionNamespace)
    }

    private func advanceRow(_ advance: AdvanceResponse) -> some View {
        HStack(spacing: Spacing.itemGap) {
            advanceLeadingAvatar(advance)
            VStack(alignment: .leading, spacing: 3) {
                Text(advance.resolvedDescription)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    // Omitted for exactly one participant — the avatar already
                    // names them, and "per Marco" next to "MR" is a repeat
                    // (`docs/design/tokens.md`'s "Text never wraps": drop a
                    // word redundant with something already on screen).
                    if advance.participants.count > 1, let names = participantNames(advance) {
                        Text(names)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .lineLimit(1)
                    }
                    if let bookedAt = advance.bookedAt {
                        Text(TraccioCore.formatDate(bookedAt, style: .dayMonthAbbreviatedYear))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkQuaternary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: Spacing.tightGap)
            VStack(alignment: .trailing, spacing: 3) {
                AmountText(
                    amount: advance.outstanding,
                    currencyCode: advance.currency,
                    kind: .income
                )
                if let label = statusBadge(advance.status) {
                    Badge(text: label, style: .neutral)
                }
            }
        }
        .padding(.vertical, Spacing.rowPadding)
        .contentShape(Rectangle())
        .rowScrollTransition()
    }

    /// A single participant's `InitialsAvatar`, or a neutral group glyph for
    /// zero or several — the same leading-element idiom `personRow` and
    /// every other list in the app already use, which this row and
    /// `personRow` were the last two missing (2026-09-19).
    @ViewBuilder
    private func advanceLeadingAvatar(_ advance: AdvanceResponse) -> some View {
        if advance.participants.count == 1, let only = advance.participants.first {
            InitialsAvatar(name: only.name)
        } else {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 36, height: 36)
                .background(Palette.neutralFill)
                .clipShape(Circle())
        }
    }

    // MARK: - Small helpers (presentation only)

    private func participantNames(_ advance: AdvanceResponse) -> String? {
        let names = advance.participants.map(\.name)
        guard !names.isEmpty else { return nil }
        return "per " + names.joined(separator: ", ")
    }

    private func statusBadge(_ status: AdvanceStatus) -> String? {
        switch status {
        case .open: nil
        case .settled: "Saldato"
        case .writtenOff: "Stralciato"
        }
    }

    private func countLabel(_ count: Int, one: String, many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    private static func filterLabel(_ status: AdvanceStatus?) -> String {
        switch status {
        case nil: "Tutti"
        case .open: "Aperti"
        case .settled: "Saldati"
        case .writtenOff: "Stralciati"
        }
    }
}
