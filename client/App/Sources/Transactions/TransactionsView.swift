import SwiftUI
import TraccioCore

/// The Movimenti screen — the transaction list backing every M2 feature
/// (transfers, advances, reimbursements, categories) that has no other entry
/// point in the client yet. Every row links to `TransactionDetailView`, where
/// a category can be confirmed or cleared (see `TransactionRow`) — the
/// client's first write-with-a-body flow. A toolbar badge links to
/// `TransfersView` whenever there is at least one transfer suggestion to
/// confirm or reject.
///
/// Follows `docs/design/canvas/Transactions.dc.html`, minus the account/
/// category filter chips.
struct TransactionsView: View {
    @State private var model = TransactionsViewModel()
    /// `.transactions` is bumped by a write on another tab that can change
    /// *which* rows should appear or how many — applying rules, deleting a
    /// category (`CategorizationViewModel`). A single row's own fields stay
    /// in sync via `onUpdate` without keying off this at all, so most writes
    /// made from this screen's own `TransactionDetailView` do not bump it —
    /// see `DataFreshness`'s doc comment.
    @Environment(DataFreshness.self) private var freshness

    var body: some View {
        NavigationStack {
            content
                .background(Palette.background)
                .navigationTitle("Movimenti")
                .refreshable { await model.load() }
                .toolbar {
                    if model.transferSuggestionCount > 0 {
                        ToolbarItem(placement: .primaryAction) {
                            NavigationLink {
                                TransfersView(
                                    client: model.client,
                                    onUpdate: { model.replace($0) },
                                    onDashboardStale: { freshness.markStale([.dashboard]) }
                                )
                            } label: {
                                Label(
                                    "\(model.transferSuggestionCount) trasferimenti",
                                    systemImage: "arrow.left.arrow.right"
                                )
                            }
                        }
                    }
                }
        }
        .task(id: freshness.token(for: .transactions)) { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let transactions) where transactions.isEmpty:
            ContentUnavailableView("Nessun movimento", systemImage: "list.bullet")
        case .loaded(let transactions):
            list(transactions)
        case .failed:
            ContentUnavailableView {
                Label("Impossibile caricare i movimenti", systemImage: "wifi.slash")
            } description: {
                Text("Verifica che il backend sia in esecuzione, poi riprova.")
            }
        }
    }

    private func list(_ transactions: [TransactionResponse]) -> some View {
        let groups = TraccioCore.groupByDay(transactions)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(groups) { group in
                    dayGroup(group, isLastGroup: group.id == groups.last?.id)
                }
            }
            .padding(20)
        }
    }

    private func dayGroup(_ group: TransactionDayGroup, isLastGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EyebrowLabel(text: title(for: group.day))
            VStack(spacing: 6) {
                ForEach(group.transactions) { transaction in
                    TransactionRow(
                        transaction: transaction,
                        categories: model.categories,
                        categoryNames: model.categoryNames,
                        advancesByTransactionID: model.advancesByTransactionID,
                        transfersByTransactionID: model.transfersByTransactionID,
                        accountsByID: model.accountsByID,
                        client: model.client,
                        onUpdate: { model.replace($0) },
                        onAdvanceUpdate: { model.updateAdvance($0, for: transaction.id) },
                        onDashboardStale: { freshness.markStale([.dashboard]) }
                    )
                    .onAppear {
                        if isLastGroup, transaction.id == group.transactions.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
                }
            }
        }
    }

    /// "Oggi" / "Ieri" for the two nearest days, else a localized day-month
    /// date; "Senza data" for the trailing group of undated rows.
    ///
    /// Mixes hardcoded Italian words with locale-driven formatting — the
    /// same half-measure `DashboardView` already has, tracked in
    /// `tasks/backlog.md`'s localization item rather than resolved here.
    private func title(for day: Date?) -> String {
        guard let day else { return "Senza data" }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Oggi" }
        if calendar.isDateInYesterday(day) { return "Ieri" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter.string(from: day)
    }
}

extension TransactionDayGroup: @retroactive Identifiable {
    /// Identity for `ForEach`: the day itself, or a fixed sentinel for the
    /// single undated group (`day == nil` can only occur once per list, per
    /// `groupByDay`'s contract).
    public var id: Date {
        day ?? Date(timeIntervalSince1970: 0)
    }
}

#Preview {
    TransactionsView()
}
