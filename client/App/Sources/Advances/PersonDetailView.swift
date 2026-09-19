import SwiftUI
import TraccioCore

/// "Dettaglio persona" — reached by tapping a row in "Chi ti deve" on
/// `AdvancesView`. One person's total receivable and the advances it comes
/// from, so a dead-end summary row becomes a place to see *which* advances a
/// person still owes on and to act on them.
///
/// No mockup covers this screen (`docs/design/canvas/` has no Anticipi
/// artboard), so it is built from existing tokens/components — one raised
/// `Card` for the figure, one grouped `Card` for the list, the same posture
/// as every other pushed detail screen. Every number is server-derived
/// (`PersonSummaryResponse`, ADR 0026); this view renders, it never sums.
struct PersonDetailView: View {
    @State private var model: PersonDetailViewModel
    private let client: any APIClientProtocol
    private let onNeedsReload: () -> Void
    private let onDashboardStale: () -> Void
    /// Shared between an advance row and its pushed detail screen so the
    /// push zooms from the row's own frame instead of sliding in
    /// (`docs/decisions/0030-liquid-glass-chrome.md`).
    @Namespace private var transitionNamespace

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// person:
    ///     The roll-up row tapped in "Chi ti deve".
    /// advances:
    ///     The advances this person appears on, already filtered by the
    ///     caller on `personKey` + `currency` — the first paint's data.
    /// client:
    ///     The API client, shared with the pushed `TransactionDetailLoader`.
    /// onNeedsReload:
    ///     Called after a write on a pushed advance, so `AdvancesView`
    ///     refetches its own list and summary.
    /// onDashboardStale:
    ///     Forwarded to `TransactionDetailLoader` — an advance write can move
    ///     the dashboard's totals.
    init(
        person: PersonSummaryResponse,
        advances: [AdvanceResponse],
        client: any APIClientProtocol = APIClient.current,
        onNeedsReload: @escaping () -> Void = {},
        onDashboardStale: @escaping () -> Void = {}
    ) {
        _model = State(
            wrappedValue: PersonDetailViewModel(person: person, advances: advances, client: client)
        )
        self.client = client
        self.onNeedsReload = onNeedsReload
        self.onDashboardStale = onDashboardStale
    }

    var body: some View {
        ScrollView {
            content
                .padding(Spacing.gutter)
        }
        .screenChrome(title)
        .task { await model.refresh() }
    }

    private var title: String {
        if case .loaded(let loaded) = model.state { return loaded.person.name }
        return "Persona"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loaded(let loaded):
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                summaryCard(loaded.person)
                advancesCard(loaded.advances)
            }
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare la persona",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.refresh() } }
            )
        }
    }

    // MARK: - Summary

    private func summaryCard(_ person: PersonSummaryResponse) -> some View {
        Card(elevation: .raised) {
            EyebrowLabel(text: "Da ricevere")
            if person.outstanding == 0 {
                Text("Saldato — questa persona non ti deve più niente.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                AmountText(
                    amount: person.outstanding,
                    currencyCode: person.currency,
                    kind: .income,
                    font: Typography.heroFigure
                )
            }
            ProgressBar(fraction: fraction(person))
            HStack {
                figure(label: "Atteso", amount: person.expected, currency: person.currency)
                Spacer()
                figure(label: "Rientrato", amount: person.reimbursed, currency: person.currency)
            }
            Text(countLabel(person.advanceCount, one: "anticipo", many: "anticipi"))
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private func figure(label: String, amount: Int, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            AmountText(amount: amount, currencyCode: currency, kind: .notCounted, font: Typography.caption)
        }
    }

    private func fraction(_ person: PersonSummaryResponse) -> Double {
        guard person.expected > 0 else { return person.outstanding == 0 ? 1 : 0 }
        return Double(person.reimbursed) / Double(person.expected)
    }

    // MARK: - Advances

    private func advancesCard(_ advances: [AdvanceResponse]) -> some View {
        Card {
            EyebrowLabel(text: "Anticipi")
            if advances.isEmpty {
                Text("Nessun anticipo aperto con questa persona.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(advances) { advance in
                        NavigationLink {
                            TransactionDetailLoader(
                                transactionID: advance.transactionID,
                                advance: advance,
                                client: client,
                                onUpdate: { _ in changed() },
                                onAdvanceChange: { _ in changed() },
                                onDashboardStale: onDashboardStale
                            )
                            #if os(iOS)
                            .navigationTransition(.zoom(sourceID: advance.id, in: transitionNamespace))
                            #endif
                        } label: {
                            advanceRow(advance)
                        }
                        .buttonStyle(.pressableRow)
                        .matchedTransitionSource(id: advance.id, in: transitionNamespace)
                        if advance.id != advances.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
        }
    }

    private func advanceRow(_ advance: AdvanceResponse) -> some View {
        HStack(spacing: Spacing.itemGap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(advance.resolvedDescription)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let bookedAt = advance.bookedAt {
                    Text(TraccioCore.formatDate(bookedAt, style: .dayMonthAbbreviatedYear))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkQuaternary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                AmountText(
                    amount: advance.outstanding, currencyCode: advance.currency, kind: .income
                )
                if let label = statusBadge(advance.status) {
                    Badge(text: label, style: .neutral)
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers (presentation only)

    private func changed() {
        Task { await model.refresh() }
        onNeedsReload()
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
}
