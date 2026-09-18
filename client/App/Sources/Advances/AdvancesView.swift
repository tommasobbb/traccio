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

    private var emptyCard: some View {
        Card {
            EyebrowLabel(text: "Anticipi")
            Text(
                "Quando paghi qualcosa per altri, segna quel movimento come anticipo dal suo dettaglio: qui vedrai chi ti deve dei soldi e quanto ti manca di rientrare."
            )
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
        }
    }

    // MARK: - Summary

    private func totalsCard(_ totals: [ReceivableTotalResponse]) -> some View {
        Card {
            EyebrowLabel(text: "Da ricevere")
            VStack(spacing: 0) {
                ForEach(totals) { total in
                    HStack(alignment: .firstTextBaseline) {
                        AmountText(
                            amount: total.outstanding,
                            currencyCode: total.currency,
                            kind: .income,
                            font: Typography.heroFigure
                        )
                        Spacer()
                        Text(countLabel(total.openAdvances, one: "anticipo aperto", many: "anticipi aperti"))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .padding(.vertical, 8)
                    if total.id != totals.last?.id {
                        Divider().overlay(Palette.separator)
                    }
                }
            }
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

    private func personRow(_ person: PersonSummaryResponse) -> some View {
        HStack(spacing: Spacing.itemGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(countLabel(person.advanceCount, one: "anticipo", many: "anticipi"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
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
        .padding(.vertical, 9)
        .contentShape(Rectangle())
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
                onDashboardStale: { freshness.markStale([.dashboard, .transactions]) },
                onDelete: { _ in Task { await model.load() } }
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
            VStack(alignment: .leading, spacing: 3) {
                Text(advance.resolvedDescription)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let names = participantNames(advance) {
                        Text(names)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .lineLimit(1)
                    }
                    if let bookedAt = advance.bookedAt {
                        Text(TraccioCore.formatDate(bookedAt, style: .dayMonthAbbreviatedYear))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkQuaternary)
                    }
                }
            }
            Spacer()
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
        .padding(.vertical, 9)
        .contentShape(Rectangle())
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
