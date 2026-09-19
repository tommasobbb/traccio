import SwiftUI
import TraccioCore

/// The Movimenti screen — the transaction list backing every M2 feature
/// (transfers, advances, reimbursements, categories). Each row carries its
/// own actions now (`docs/decisions/0036-movimenti-row-actions.md`): a tap on
/// the leading tile confirms/clears a category via `CategoryPickerSheet`, a
/// long-press opens a context menu (mark as advance, link as transfer, and —
/// on a manual account — edit/delete), and tapping the rest of the row still
/// pushes to `TransactionDetailView` for the sections that belong there
/// (event, an *existing* advance, a confirmed transfer). A card at the top of
/// the list links to `TransfersView` whenever there is at least one transfer
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
    /// Which row-level action sheet is presented, if any
    /// (`docs/decisions/0036-movimenti-row-actions.md`). One `Identifiable`
    /// enum rather than one `@State` boolean per sheet — only one row action
    /// can be in flight at a time.
    @State private var rowAction: RowAction?
    /// Presents `CreateRuleFromTransactionSheet`, nested inside
    /// `CategoryPickerSheet` — a `@State` here (not on the sheet itself)
    /// because this view owns the write and its outcome, same as every other
    /// sheet's dismissal.
    @State private var isPresentingCreateRuleSheet = false
    /// The row awaiting a delete confirmation, from the context menu's
    /// "Elimina" — separate from `rowAction` since `.confirmationDialog`'s
    /// button always dismisses on tap, so it can't stay open through a
    /// failed delete the way a `.sheet(item:)` can; `deleteFailureMessage`
    /// carries the outcome to a follow-up `.alert` instead.
    @State private var deleteTarget: TransactionResponse?
    @State private var deleteFailureMessage: String?

    /// One row-level action presented as a sheet, keyed by the transaction it
    /// targets (`docs/decisions/0036-movimenti-row-actions.md`). Delete is
    /// not one of these — see `deleteTarget`.
    enum RowAction: Identifiable {
        case categorize(TransactionResponse)
        case advance(TransactionResponse)
        case edit(TransactionResponse)

        var id: UUID {
            switch self {
            case .categorize(let transaction), .advance(let transaction), .edit(let transaction):
                transaction.id
            }
        }
    }

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
            .sheet(item: $rowAction) { action in
                switch action {
                case .categorize(let transaction):
                    CategoryPickerSheet(
                        categories: model.categories,
                        transaction: transaction,
                        isUpdating: model.isUpdatingRow,
                        failureMessage: rowActionFailureMessage,
                        onSeedDefaults: {
                            Task { await model.seedDefaultCategories() }
                        },
                        onConfirm: { categoryID in
                            Task {
                                if await model.confirmCategory(categoryID, for: transaction.id) {
                                    freshness.markStale([.dashboard])
                                    rowAction = nil
                                }
                            }
                        },
                        onClear: {
                            Task {
                                if await model.clearCategory(for: transaction.id) {
                                    freshness.markStale([.dashboard])
                                    rowAction = nil
                                }
                            }
                        },
                        onCancel: { rowAction = nil },
                        isPresentingCreateRuleSheet: $isPresentingCreateRuleSheet,
                        createRuleFailureMessage: createRuleFailureMessage,
                        onCreateRule: { matchKind, pattern in
                            guard let categoryID = transaction.confirmedCategoryID else { return }
                            Task {
                                if await model.createRuleAndApplyRules(
                                    categoryID: categoryID, matchKind: matchKind, pattern: pattern
                                ) {
                                    freshness.markStale([.transactions, .dashboard])
                                    isPresentingCreateRuleSheet = false
                                    rowAction = nil
                                }
                            }
                        }
                    )
                case .advance(let transaction):
                    CreateAdvanceSheet(
                        transaction: transaction,
                        isCreating: model.isUpdatingRow,
                        failureMessage: rowActionFailureMessage != nil
                            ? "Non è stato possibile creare l'anticipo. Riprova." : nil,
                        onCreate: { ownShare, participants in
                            Task {
                                if await model.createAdvance(
                                    ownShare: ownShare, participants: participants, for: transaction.id
                                ) {
                                    freshness.markStale([.dashboard])
                                    rowAction = nil
                                }
                            }
                        },
                        onCancel: { rowAction = nil }
                    )
                case .edit(let transaction):
                    EditManualTransactionSheet(
                        transaction: transaction,
                        isSaving: model.isUpdatingRow,
                        failureMessage: rowActionFailureMessage != nil
                            ? "Non è stato possibile salvare il movimento. Riprova." : nil,
                        onSave: { amount, currency, valueDate, description in
                            Task {
                                if await model.editManualTransaction(
                                    transactionID: transaction.id, amount: amount, currency: currency,
                                    valueDate: valueDate, description: description
                                ) {
                                    freshness.markStale([.dashboard])
                                    rowAction = nil
                                }
                            }
                        },
                        onCancel: { rowAction = nil }
                    )
                }
            }
            .confirmationDialog(
                "Eliminare questo movimento?",
                isPresented: Binding(
                    get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { transaction in
                Button("Elimina", role: .destructive) {
                    Task {
                        if await model.deleteManualTransaction(transaction.id) {
                            freshness.markStale([.dashboard])
                        } else {
                            deleteFailureMessage = rowDeleteFailureMessage
                        }
                        deleteTarget = nil
                    }
                }
                Button("Annulla", role: .cancel) {}
            } message: { _ in
                Text("L'operazione non è reversibile.")
            }
            .alert(
                "Impossibile eliminare",
                isPresented: Binding(
                    get: { deleteFailureMessage != nil }, set: { if !$0 { deleteFailureMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(deleteFailureMessage ?? "")
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
            // The toolbar is a filter button and "+": the transfer count
            // moved to a card at the top of the list (more discoverable than
            // a mute glyph that vanishes at zero), and "Collega trasferimento"
            // moved into the row's own context menu as "Collega a…"
            // (`docs/decisions/0036-movimenti-row-actions.md`) — the old
            // "•••" overflow `Menu` had exactly that one entry, a
            // service menu dressed as a primary action.
            //
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
            // A fixed spacer splits "Filtri" from "+" into two glass capsules
            // instead of one merged group — "+" is the primary creation
            // action and reads as such on its own
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

    // MARK: Row actions (docs/decisions/0036-movimenti-row-actions.md)

    /// `CategoryPickerSheet`'s banner copy for `model.rowActionFailure`, or
    /// `nil` when there is none. `.duplicateRule` reads specifically inside
    /// `CreateRuleFromTransactionSheet` instead (`createRuleFailureMessage`),
    /// so it is not surfaced here.
    private var rowActionFailureMessage: String? {
        switch model.rowActionFailure {
        case nil, .duplicateRule: nil
        case .generic, .transactionInUse: "Non è stato possibile completare l'operazione. Riprova."
        }
    }

    /// `CreateRuleFromTransactionSheet`'s own failure copy — separate from
    /// `rowActionFailureMessage` so a duplicate-rule error reads specifically
    /// inside the sheet that caused it.
    private var createRuleFailureMessage: String? {
        switch model.rowActionFailure {
        case .duplicateRule: "Esiste già una regola identica."
        case nil, .generic, .transactionInUse: nil
        }
    }

    /// The follow-up `.alert`'s copy after a failed delete — the
    /// `.confirmationDialog` itself already dismissed on the button tap, so
    /// this is the only place left to say why (`deleteFailureMessage`).
    /// `.transactionInUse` names the specific, recoverable cause; anything
    /// else falls back to a generic retry.
    private var rowDeleteFailureMessage: String {
        model.rowActionFailure == .transactionInUse
            ? "Il movimento è collegato a un trasferimento o a un anticipo. Scollegalo prima di eliminarlo."
            : "Non è stato possibile eliminare il movimento. Riprova."
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

    /// One stable `ScrollView` across every state, so it — and the
    /// `.refreshable` control it hosts — never gets torn down mid-request.
    /// Before this, each state built its own `ScrollView` (or none, for the
    /// empty/failed states), so a refresh's own transition to `.loading`
    /// destroyed the very scroll view running its Task, surfacing the
    /// resulting cancellation as "impossibile caricare i movimenti" — see
    /// `TransactionsViewModel.loadPage()`'s cancellation guard for the other
    /// half of that fix.
    private var content: some View {
        ScrollView {
            innerContent
                .padding(Spacing.gutter)
        }
    }

    @ViewBuilder
    private var innerContent: some View {
        switch model.state {
        case .idle, .loading:
            ListSkeleton()
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
        return VStack(alignment: .leading, spacing: Spacing.cardGap) {
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
    }

    /// A day's rows in one card — one border, one resting shadow, hairline
    /// dividers between rows (ADR 0008's 2026-09-08 tone revision). The rows
    /// carry their own padding, so the card's `contentPadding` is `0` and its
    /// rounded corners clip the row fills.
    private func dayGroup(_ group: TransactionDayGroup, isLastGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tightGap) {
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
                            actions: TransactionRow.Actions(
                                onCategorize: { transaction in
                                    model.clearRowActionFailure()
                                    rowAction = .categorize(transaction)
                                },
                                onMarkAsAdvance: { transaction in
                                    model.clearRowActionFailure()
                                    rowAction = .advance(transaction)
                                },
                                onLinkFrom: { transaction in
                                    model.enterSelection(anchor: transaction.id)
                                },
                                onEdit: { transaction in
                                    model.clearRowActionFailure()
                                    rowAction = .edit(transaction)
                                },
                                onDelete: { transaction in
                                    model.clearRowActionFailure()
                                    deleteTarget = transaction
                                }
                            ),
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
            isSelectable = TraccioCore.canStartTransferLink(transaction)
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
