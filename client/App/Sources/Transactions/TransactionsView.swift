import SwiftUI
import TraccioCore

/// The Movimenti screen — the transaction list backing every M2 feature
/// (transfers, advances, reimbursements, categories) that has no other entry
/// point in the client yet. Every row links to `TransactionDetailView`, where
/// a category can be confirmed or cleared (see `TransactionRow`) — the
/// client's first write-with-a-body flow. A card at the top of the list
/// links to `TransfersView` whenever there is at least one transfer
/// suggestion to confirm or reject.
///
/// Follows `docs/design/canvas/TransactionsV2.dc.html` (Fase B redesign):
/// toolbar down to a "•••" overflow, a filter button, and "+", suggestions
/// surfaced as a top-of-list card. One filter entry point (the toolbar
/// button opens `TransactionFiltersSheet`); the active filters show as
/// removable tokens under the search field, and that row is absent entirely
/// when nothing is filtered. Filtering happens server-side
/// (`TransactionFilter`, `TransactionsViewModel.applyFilter(_:)`), never on
/// an already-fetched page.
///
/// `TransferSuggestionsLinkCard`, `TransactionSelectionBar`, and
/// `ActiveFilterTokensRow` each live in their own file next to this one —
/// this view only wires them to `TransactionsViewModel` and lays them out.
struct TransactionsView: View {
    @State private var model: TransactionsViewModel
    /// Bound to `.searchable`. Kept separate from `model.filter.searchTerm`
    /// so every keystroke updates the field instantly while the debounced
    /// request lags behind it — see `TransactionsViewModel.updateSearchTerm(_:)`.
    @State private var searchText: String
    /// `.transactions` is bumped by a write on another tab that can change
    /// *which* rows should appear or how many — applying rules, deleting a
    /// category (`CategorizationViewModel`). A single row's own fields stay
    /// in sync via `onUpdate` without keying off this at all, so most writes
    /// made from this screen's own `TransactionDetailView` do not bump it —
    /// see `DataFreshness`'s doc comment.
    @Environment(DataFreshness.self) private var freshness
    /// Presents `CreateManualTransactionSheet` — a hand-entered movement on a
    /// manual account (ADR 0020).
    @State private var isCreatingTransaction = false
    /// Presents `FundedPaymentOrientationSheet` once a same-sign selection is
    /// ready to link — sign alone doesn't say which leg funds which, unlike
    /// a two-sided transfer, so the user picks explicitly (ADR 0022).
    @State private var isChoosingFundedPaymentOrientation = false
    /// Shared between a row and its pushed `TransactionDetailView` so the
    /// push can zoom from the row's own frame (`TransactionRow`, iOS only —
    /// `ZoomNavigationTransition` is unavailable on macOS).
    @Namespace private var transitionNamespace

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// initialFilter:
    ///     The filter to load with, before any user interaction — lets a
    ///     drill-through from Panoramica (`TransactionsDrillThrough`) open
    ///     this tab already filtered. Defaults to no filtering.
    init(initialFilter: TransactionFilter = .none) {
        _model = State(wrappedValue: TransactionsViewModel(initialFilter: initialFilter))
        _searchText = State(wrappedValue: initialFilter.searchTerm ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterRow
                content
            }
            .screenChrome("Movimenti", style: .tabRoot)
            .searchable(text: $searchText, prompt: "Cerca nei movimenti")
            .onChange(of: searchText) { _, newValue in model.updateSearchTerm(newValue) }
            .animation(.easeInOut(duration: 0.2), value: model.state.tag)
            .animation(.easeInOut(duration: 0.2), value: model.isSelecting)
            .sensoryFeedback(.success, trigger: model.successTick)
            .refreshable { if !model.isSelecting { await model.load() } }
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if model.isSelecting { selectionBar }
            }
            .sheet(isPresented: $isCreatingTransaction) {
                CreateManualTransactionSheet(
                    accounts: model.manualAccounts,
                    isCreating: model.isCreating,
                    failureMessage: model.createFailure != nil
                        ? "Non è stato possibile aggiungere il movimento. Riprova." : nil,
                    onCreate: { accountID, amount, currency, valueDate, description in
                        Task {
                            let ok = await model.createManualTransaction(
                                accountID: accountID, amount: amount, currency: currency,
                                valueDate: valueDate, description: description,
                                confirmedCategoryID: nil
                            )
                            if ok {
                                freshness.markStale([.dashboard])
                                isCreatingTransaction = false
                            }
                        }
                    },
                    onCancel: { isCreatingTransaction = false }
                )
            }
            .sheet(isPresented: $isFilteringOpen) {
                TransactionFiltersSheet(
                    accountID: model.filter.accountID,
                    category: model.filter.category,
                    period: selectedPeriodPreset,
                    accounts: sortedAccounts,
                    categoryTree: TraccioCore.categoryTree(model.categories),
                    periodTitle: { title(for: $0) },
                    onApply: { accountID, category, period in
                        applyFilters(accountID: accountID, category: category, period: period)
                    }
                )
            }
            .sheet(isPresented: $isChoosingFundedPaymentOrientation) {
                let selected = model.selectedTransactions
                if selected.count == 2 {
                    FundedPaymentOrientationSheet(
                        a: selected[0],
                        b: selected[1],
                        accountsByID: model.accountsByID,
                        isLinking: model.isLinking,
                        failureMessage: linkFailureMessage,
                        onConfirm: { fundingID in
                            Task {
                                if await model.linkSelectedAsFundedPayment(fundingID: fundingID) {
                                    freshness.markStale([.dashboard])
                                    isChoosingFundedPaymentOrientation = false
                                }
                            }
                        },
                        onCancel: { isChoosingFundedPaymentOrientation = false }
                    )
                }
            }
        }
        .task(id: freshness.token(for: .transactions)) { await model.load() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fine") { model.exitSelection() }
            }
        } else {
            // The toolbar is "•••" overflow, a filter button, and "+": the
            // transfer count moved to a card at the top of the list (more
            // discoverable than a mute glyph that vanishes at zero), and
            // "Collega trasferimento" is a secondary action, not a peer of "+".
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        model.enterSelection()
                    } label: {
                        Label("Collega trasferimento", systemImage: "arrow.triangle.merge")
                    }
                } label: {
                    Label("Altro", systemImage: "ellipsis")
                }
            }
            // One entry point for all three filter dimensions. `.fill` when
            // anything is filtered; the active filters themselves show as
            // removable tokens under the search field (`filterRow`).
            ToolbarItem(placement: .primaryAction) {
                Button { isFilteringOpen = true } label: {
                    Label(
                        "Filtri",
                        systemImage: hasActiveFilters
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                    // A symbol morph instead of a snap when a filter is
                    // applied/cleared (`docs/decisions/0031-visual-coherence-pass.md`).
                    .contentTransition(.symbolEffect(.replace))
                }
                .animation(.easeInOut(duration: 0.2), value: hasActiveFilters)
            }
            // A fixed spacer splits "Altro"/"Filtri" from "+" into two glass
            // capsules instead of one merged group — "+" is the primary
            // creation action and reads as such on its own
            // (`docs/decisions/0031-visual-coherence-pass.md`).
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { isCreatingTransaction = true } label: {
                    Label("Nuovo movimento", systemImage: "plus")
                }
            }
        }
    }

    // MARK: Transfer-pairing selection bar

    private var selectionBar: some View {
        TransactionSelectionBar(
            selectedTransactions: model.selectedTransactions,
            canLinkAsTwoSided: model.canLinkAsTwoSided,
            canLinkAsFundedPaymentSelection: model.canLinkAsFundedPaymentSelection,
            isLinking: model.isLinking,
            linkFailure: model.linkFailure,
            onLinkAsTransfer: {
                Task {
                    if await model.linkSelectedAsTransfer() {
                        freshness.markStale([.dashboard])
                    }
                }
            },
            onChooseFundedPaymentOrientation: { isChoosingFundedPaymentOrientation = true }
        )
    }

    private var linkFailureMessage: String? {
        switch model.linkFailure {
        case nil: nil
        case .alreadyLinked: "Uno dei due movimenti è già in un trasferimento."
        case .notLinkable: "Questi due movimenti non possono formare un trasferimento."
        case .generic: "Non è stato possibile collegare i movimenti. Riprova."
        }
    }

    // MARK: Active-filter tokens

    /// One removable token per active filter dimension, or nothing at all when
    /// no filter is set — so the list starts right under the search field in
    /// the common case. Setting a filter is the toolbar's filter button (which
    /// opens `TransactionFiltersSheet`); this row only *shows and clears* what
    /// is active. Independent of `model.state`: a load failure or an empty
    /// result doesn't hide it.
    private var filterRow: some View {
        ActiveFilterTokensRow(
            accountToken: model.filter.accountID.map { _ in
                .init(title: accountFilterTitle) {
                    applyFilters(accountID: nil, category: model.filter.category, period: selectedPeriodPreset)
                }
            },
            categoryToken: model.filter.category == .any ? nil : .init(title: categoryFilterTitle) {
                applyFilters(accountID: model.filter.accountID, category: .any, period: selectedPeriodPreset)
            },
            periodToken: selectedPeriodPreset == .all ? nil : .init(title: periodFilterTitle) {
                applyFilters(accountID: model.filter.accountID, category: model.filter.category, period: .all)
            }
        )
    }

    /// Whether any of the three dimensions is set — drives the toolbar
    /// button's `.fill` variant.
    private var hasActiveFilters: Bool {
        model.filter.accountID != nil
            || model.filter.category != .any
            || selectedPeriodPreset != .all
    }

    /// Presents `TransactionFiltersSheet`.
    @State private var isFilteringOpen = false

    /// The preset last applied via the period chip. Not derived from
    /// `model.filter.start`/`.end` — those are plain `Date?` and can't be
    /// mapped back to a preset unambiguously — so this is its own state,
    /// defaulting to `.all` (no bound), matching a fresh `TransactionFilter`.
    @State private var selectedPeriodPreset: TransactionPeriodPreset = .all

    private var periodFilterTitle: String { title(for: selectedPeriodPreset) }

    /// Italian labels for `TransactionPeriodPreset` — display copy belongs in
    /// the view, not `TraccioCore` (see the type's own doc comment).
    private func title(for preset: TransactionPeriodPreset) -> String {
        switch preset {
        case .thisMonth: "Questo mese"
        case .lastMonth: "Mese scorso"
        case .last3Months: "Ultimi 3 mesi"
        case .thisYear: "Quest'anno"
        // "Dall'inizio", not "Tutto": with a tracking start date set
        // (ADR 0024) this still stops at that floor server-side.
        case .all: "Dall'inizio"
        }
    }

    /// Apply the whole selection the sheet accumulated — account, category,
    /// and period preset — in one `applyFilter` call, so the list behind the
    /// sheet reloads once, not once per dimension.
    private func applyFilters(
        accountID: UUID?,
        category: TransactionFilter.CategoryFilter,
        period: TransactionPeriodPreset
    ) {
        selectedPeriodPreset = period
        let range = period.range()
        Task {
            var newFilter = model.filter
            newFilter.accountID = accountID
            newFilter.category = category
            newFilter.start = range.start
            newFilter.end = range.end
            await model.applyFilter(newFilter)
        }
    }

    private var sortedAccounts: [AccountResponse] {
        model.accountsByID.values.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    private var accountFilterTitle: String {
        guard let accountID = model.filter.accountID else { return "Tutti i conti" }
        return model.accountsByID[accountID]?.displayName ?? "Conto"
    }

    private var categoryFilterTitle: String {
        switch model.filter.category {
        case .any: "Categoria"
        case .uncategorized: "Senza categoria"
        case .some(let categoryID):
            model.categories.first { $0.id == categoryID }?.name ?? "Categoria"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ScrollView {
                ListSkeleton()
                    .padding(Spacing.gutter)
            }
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
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                if model.transferSuggestionCount > 0 {
                    TransferSuggestionsLinkCard(
                        count: model.transferSuggestionCount,
                        client: model.client,
                        onUpdate: { model.replace($0) },
                        onDashboardStale: { freshness.markStale([.dashboard]) }
                    )
                }
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(groups) { group in
                        dayGroup(group, isLastGroup: group.id == groups.last?.id)
                    }
                }
            }
            .padding(Spacing.gutter)
        }
    }

    /// A day's rows in one card — one border, one resting shadow, hairline
    /// dividers between rows (ADR 0008's 2026-09-08 tone revision). The rows
    /// carry their own padding, so the card's `contentPadding` is `0` and its
    /// rounded corners clip the row fills.
    private func dayGroup(_ group: TransactionDayGroup, isLastGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EyebrowLabel(text: title(for: group.day))
            Card(elevation: .resting, contentPadding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(group.transactions.enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 {
                            Divider().overlay(Palette.separatorSubtle).padding(.leading, 16)
                        }
                        TransactionRow(
                            transaction: transaction,
                            categories: model.categories,
                            categoryNames: model.categoryNames,
                            categoriesByID: model.categoriesByID,
                            advancesByTransactionID: model.advancesByTransactionID,
                            transfersByTransactionID: model.transfersByTransactionID,
                            accountsByID: model.accountsByID,
                            events: model.events,
                            client: model.client,
                            onUpdate: { model.replace($0) },
                            onAdvanceUpdate: { model.updateAdvance($0, for: transaction.id) },
                            onDashboardStale: { freshness.markStale([.dashboard]) },
                            onRulesApplied: { freshness.markStale([.transactions, .dashboard]) },
                            onDelete: { model.remove(id: $0) },
                            selection: rowSelection(for: transaction),
                            namespace: transitionNamespace
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
    }

    /// The row's selection state while transfer-pairing mode is active, or
    /// `nil` when it isn't (the row stays a normal `NavigationLink`).
    ///
    /// A row is *selectable* when: it's already selected (so it can be
    /// deselected); or fewer than two are selected and it can still form a
    /// valid pair — with no other selection, any `personal`/non-`rejected`/
    /// non-zero row qualifies; with one selected, only a row that
    /// `TraccioCore.canLinkAsTransfer` or `TraccioCore.canLinkAsFundedPayment`
    /// accepts alongside it (a two-sided transfer or a funded payment — see
    /// `FundedPaymentOrientationSheet` for how the same-sign case is
    /// oriented).
    private func rowSelection(for transaction: TransactionResponse) -> TransactionRow.Selection? {
        guard model.isSelecting else { return nil }
        let isSelected = model.selectedIDs.contains(transaction.id)
        let others = model.selectedTransactions.filter { $0.id != transaction.id }
        let isSelectable: Bool
        if isSelected {
            isSelectable = true
        } else if model.selectedIDs.count >= 2 {
            isSelectable = false
        } else if let anchor = others.first {
            isSelectable =
                TraccioCore.canLinkAsTransfer(anchor, transaction)
                || TraccioCore.canLinkAsFundedPayment(anchor, transaction)
        } else {
            isSelectable =
                transaction.role == .personal && transaction.status != .rejected
                && transaction.amount != 0
        }
        return TransactionRow.Selection(
            isSelected: isSelected,
            isSelectable: isSelectable,
            onToggle: { model.toggleSelection(transaction.id) }
        )
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
        return TraccioCore.formatDate(day, style: .dayMonth)
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
