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
/// Follows `docs/design/canvas/Transactions.dc.html`, including the account/
/// category filter chips — the filtering happens server-side
/// (`TransactionFilter`, `TransactionsViewModel.applyFilter(_:)`), never on
/// an already-fetched page.
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
            VStack(spacing: 0) {
                filterRow
                content
            }
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

    // MARK: Filter chips

    /// "Tutti i conti" / "Categoria" chips (`docs/design/canvas/Transactions.dc.html`).
    /// Always visible, independent of `model.state` — these are controls, not
    /// content, so a load failure or an empty result doesn't hide them.
    private var filterRow: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Tutti i conti") { applyAccountFilter(nil) }
                if !model.accountsByID.isEmpty {
                    Divider()
                    ForEach(sortedAccounts) { account in
                        Button(account.name ?? "Conto") { applyAccountFilter(account.id) }
                    }
                }
            } label: {
                FilterChip(title: accountFilterTitle, isActive: model.filter.accountID != nil)
            }
            Menu {
                Button("Tutte le categorie") { applyCategoryFilter(.any) }
                Button("Senza categoria") { applyCategoryFilter(.uncategorized) }
                if !model.categories.isEmpty {
                    Divider()
                    ForEach(model.categories) { category in
                        Button(category.name) { applyCategoryFilter(.some(category.id)) }
                    }
                }
            } label: {
                FilterChip(title: categoryFilterTitle, isActive: model.filter.category != .any)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var sortedAccounts: [AccountResponse] {
        model.accountsByID.values.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    private var accountFilterTitle: String {
        guard let accountID = model.filter.accountID else { return "Tutti i conti" }
        return model.accountsByID[accountID]?.name ?? "Conto"
    }

    private var categoryFilterTitle: String {
        switch model.filter.category {
        case .any: "Categoria"
        case .uncategorized: "Senza categoria"
        case .some(let categoryID):
            model.categories.first { $0.id == categoryID }?.name ?? "Categoria"
        }
    }

    private func applyAccountFilter(_ accountID: UUID?) {
        Task {
            await model.applyFilter(
                TransactionFilter(
                    accountID: accountID, eventID: model.filter.eventID, category: model.filter.category
                )
            )
        }
    }

    private func applyCategoryFilter(_ category: TransactionFilter.CategoryFilter) {
        Task {
            await model.applyFilter(
                TransactionFilter(
                    accountID: model.filter.accountID, eventID: model.filter.eventID, category: category
                )
            )
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let transactions) where transactions.isEmpty:
            emptyState
        case .loaded(let transactions):
            list(transactions)
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare i movimenti",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.load() } }
            )
        }
    }

    /// Distinguishes "no movements at all" from "no movements match this
    /// filter" — the latter offers a way back to the unfiltered list rather
    /// than reading as an empty account.
    @ViewBuilder
    private var emptyState: some View {
        if model.filter == .none {
            EmptyState(systemImage: "list.bullet", title: "Nessun movimento")
        } else {
            EmptyState(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "Nessun movimento con questo filtro",
                actionTitle: "Rimuovi filtro",
                action: { Task { await model.applyFilter(.none) } }
            )
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
                        events: model.events,
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
