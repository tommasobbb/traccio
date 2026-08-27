import Foundation
import TraccioCore

/// A fake `APIClientProtocol` for view-model tests — no network stub needed.
///
/// An `actor` rather than a class with `@unchecked Sendable`:
/// `APIClientProtocol` requires `Sendable` conformance, and an actor gets that
/// for free while still letting a test configure canned responses safely
/// across `await` boundaries. Lives in the test target, not `TraccioCore`
/// (`.claude/rules/swift.md`): a production module should not ship a fake.
///
/// Every method has a safe default (an empty collection, or a placeholder
/// value) so a test that doesn't care about a given call doesn't need to
/// configure it. Fixtures are synthetic throughout
/// (`.claude/rules/data-safety.md`).
actor FakeAPIClient: APIClientProtocol {
    /// Thrown by `transaction(id:)` when no result was configured — a test
    /// that hits this forgot to call `setTransaction(_:)`.
    struct NotConfigured: Error {}

    // MARK: Configurable results

    var accountsToReturn: [AccountResponse] = []
    var accountsError: Error?
    var renameAccountToReturn: AccountResponse?
    var renameAccountError: Error?
    var accountAppearanceToReturn: AccountResponse?
    var accountAppearanceError: Error?
    var createManualAccountToReturn: AccountResponse?
    var createManualAccountError: Error?
    var deleteAccountError: Error?
    var createManualTransactionToReturn: TransactionResponse?
    var createManualTransactionError: Error?
    var editManualTransactionToReturn: TransactionResponse?
    var editManualTransactionError: Error?
    var deleteManualTransactionError: Error?
    var healthToReturn = HealthResponse(status: "ok", version: "test")
    var healthError: Error?
    var dashboardSummaryToReturn = DashboardSummaryResponse(currencies: [])
    var dashboardSummaryError: Error?
    /// Every `dashboardSummary` call's full argument set, in order — lets a
    /// test assert the period, granularity, time zone, and comparison window
    /// a reload actually requested.
    private(set) var receivedDashboardSummaryRequests: [
        (
            start: Date?, end: Date?, granularity: BucketGranularity, tz: String?, compareStart: Date?,
            compareEnd: Date?
        )
    ] = []
    var transactionToReturn: TransactionResponse?
    /// Per-id overrides for `transaction(id:)`, checked before
    /// `transactionToReturn` — needed wherever a test fetches two different
    /// transactions by id in one call (e.g. both legs of a transfer).
    var transactionsByID: [UUID: TransactionResponse] = [:]
    var transactionError: Error?
    var confirmCategoryError: Error?
    var clearCategoryError: Error?
    var transactionsToReturn: [TransactionResponse] = []
    var categoriesToReturn: [CategoryResponse] = []
    var categoriesError: Error?
    var seedDefaultCategoriesToReturn: [CategoryResponse] = []
    var seedDefaultCategoriesError: Error?
    var createCategoryToReturn: CategoryResponse?
    var createCategoryError: Error?
    var renameCategoryToReturn: CategoryResponse?
    var renameCategoryError: Error?
    var categoryAppearanceToReturn: CategoryResponse?
    var categoryAppearanceError: Error?
    var moveCategoryToReturn: CategoryResponse?
    var moveCategoryError: Error?
    var deleteCategoryError: Error?
    var rulesToReturn: [RuleResponse] = []
    var rulesError: Error?
    var createRuleToReturn: RuleResponse?
    var createRuleError: Error?
    var deleteRuleError: Error?
    var applyRulesToReturn = ApplyRulesResponse(rulesApplied: 0, matched: 0, cleared: 0)
    var applyRulesError: Error?
    var advancesToReturn: [AdvanceResponse] = []
    var advanceToReturn: AdvanceResponse?
    var advanceError: Error?
    var createAdvanceToReturn: AdvanceResponse?
    var createAdvanceError: Error?
    var deleteAdvanceError: Error?
    var writeOffAdvanceToReturn: AdvanceResponse?
    var writeOffAdvanceError: Error?
    var reopenAdvanceToReturn: AdvanceResponse?
    var reopenAdvanceError: Error?
    var createReimbursementToReturn: ReimbursementResponse?
    var createReimbursementError: Error?
    var reimbursementsToReturn: [ReimbursementResponse] = []
    var reimbursementsError: Error?
    var deleteReimbursementError: Error?
    var connectionsToReturn: [ConnectionResponse] = []
    var institutionsToReturn: [InstitutionResponse] = []
    var institutionsError: Error?
    var startConnectionToReturn = StartConnectionResponse(
        connectionID: UUID(), authorizationURL: "https://sca.example.test/go"
    )
    var startConnectionError: Error?
    var syncConnectionToReturn = SyncResponse(accountsSynced: 0, transactionsSynced: 0)
    var reauthorizeConnectionToReturn = StartConnectionResponse(
        connectionID: UUID(), authorizationURL: "https://sca.example.test/go"
    )
    var transferSuggestionsToReturn: [TransferSuggestionResponse] = []
    var transferSuggestionsError: Error?
    var transfersToReturn: [TransferResponse] = []
    var confirmTransferToReturn: TransferResponse?
    var confirmTransferError: Error?
    var rejectTransferError: Error?
    var deleteTransferError: Error?
    var eventsToReturn: [EventResponse] = []
    var eventsError: Error?
    var eventToReturn: EventResponse?
    var eventError: Error?
    var eventTransactionsToReturn: [TransactionResponse] = []
    var eventTransactionsError: Error?
    var createEventToReturn: EventResponse?
    var createEventError: Error?
    var deleteEventError: Error?
    var closeEventToReturn: EventResponse?
    var closeEventError: Error?
    var reopenEventToReturn: EventResponse?
    var reopenEventError: Error?
    var assignTransactionError: Error?
    var unassignTransactionError: Error?

    // MARK: Call recording

    private(set) var confirmedCategoryIDs: [UUID] = []
    private(set) var clearCategoryCallCount = 0
    private(set) var transactionFetchCount = 0
    /// Every `filter` the view model under test passed to `transactions(filter:limit:offset:)`,
    /// in call order — proves `TransactionsViewModel.applyFilter(_:)` and
    /// `loadMore()` send it, not just hold it.
    private(set) var receivedTransactionsFilters: [TransactionFilter] = []
    /// Every `offset` passed to `transactions(filter:limit:offset:)`, in call
    /// order — proves a filter change resets pagination to the first page.
    private(set) var receivedTransactionsOffsets: [Int] = []
    private(set) var confirmedTransferPairs: [RecordedTransferPair] = []
    private(set) var rejectedTransferPairs: [RecordedTransferPair] = []
    private(set) var deletedTransferIDs: [UUID] = []
    private(set) var createdAdvanceRequests: [CreateAdvanceRequest] = []
    private(set) var deletedAdvanceIDs: [UUID] = []
    private(set) var writeOffAdvanceCallCount = 0
    private(set) var reopenAdvanceCallCount = 0
    private(set) var createdReimbursementRequests: [CreateReimbursementRequest] = []
    private(set) var deletedReimbursementIDs: [UUID] = []
    private(set) var createdCategoryNames: [String] = []
    private(set) var createCategoryRequests: [RecordedCategoryCreate] = []
    private(set) var renamedCategories: [RecordedRename] = []
    private(set) var categoryAppearanceUpdates: [RecordedCategoryAppearance] = []
    private(set) var movedCategories: [RecordedCategoryMove] = []
    private(set) var deletedCategoryIDs: [UUID] = []
    private(set) var rulesFetchCount = 0
    private(set) var createdRuleRequests: [CreateRuleRequest] = []
    private(set) var deletedRuleIDs: [UUID] = []
    private(set) var applyRulesCallCount = 0
    private(set) var eventsFetchCount = 0
    private(set) var eventFetchCount = 0
    private(set) var eventTransactionsFetchCount = 0
    private(set) var createdEventRequests: [CreateEventRequest] = []
    private(set) var deletedEventIDs: [UUID] = []
    private(set) var closeEventCallCount = 0
    private(set) var reopenEventCallCount = 0
    private(set) var assignedEventMembers: [RecordedEventMember] = []
    private(set) var unassignedEventMembers: [RecordedEventMember] = []
    private(set) var renamedAccounts: [RecordedAccountRename] = []
    private(set) var accountAppearanceUpdates: [RecordedAccountAppearance] = []
    private(set) var createdManualAccounts: [RecordedManualAccountCreate] = []
    private(set) var deletedAccountIDs: [UUID] = []
    private(set) var createdManualTransactions: [RecordedManualTransactionCreate] = []
    private(set) var editedManualTransactions: [RecordedManualTransactionEdit] = []
    private(set) var deletedManualTransactionIDs: [UUID] = []
    /// Every `country` passed to `institutions(country:)`, in call order.
    private(set) var receivedInstitutionsCountries: [String] = []
    /// Every `startConnection(institution:country:)` call, for asserting
    /// exactly which institution and country were sent.
    private(set) var startedConnections: [RecordedStartConnection] = []

    /// A recorded `startConnection(institution:country:logo:)` call.
    struct RecordedStartConnection: Equatable {
        let institution: String
        let country: String
        let logo: String?
    }

    /// A recorded `renameCategory(id:name:)` call, for asserting exactly
    /// which category was renamed to what.
    struct RecordedRename: Equatable {
        let id: UUID
        let name: String
    }

    /// A recorded `createCategory(name:parentID:color:icon:)` call.
    struct RecordedCategoryCreate: Equatable {
        let name: String
        let parentID: UUID?
        let color: PaletteColor?
        let icon: CategoryIcon?
    }

    /// A recorded `setCategoryAppearance(id:color:icon:)` call.
    struct RecordedCategoryAppearance: Equatable {
        let id: UUID
        let color: PaletteColor
        let icon: CategoryIcon?
    }

    /// A recorded `moveCategory(id:parentID:)` call.
    struct RecordedCategoryMove: Equatable {
        let id: UUID
        let parentID: UUID?
    }

    /// A recorded `renameAccount(id:alias:)` call.
    struct RecordedAccountRename: Equatable {
        let id: UUID
        let alias: String?
    }

    /// A recorded `setAccountAppearance(id:color:icon:)` call.
    struct RecordedAccountAppearance: Equatable {
        let id: UUID
        let color: PaletteColor?
        let icon: AccountIcon?
    }

    /// A recorded `createManualAccount(...)` call (ADR 0020).
    struct RecordedManualAccountCreate: Equatable {
        let alias: String
        let kind: AccountKind
        let currency: String
        let color: PaletteColor?
        let icon: AccountIcon?
    }

    /// A recorded `createManualTransaction(_:)` call (ADR 0020).
    struct RecordedManualTransactionCreate: Equatable {
        let accountID: UUID
        let amount: Int
        let currency: String
        let valueDate: Date
        let description: String
        let confirmedCategoryID: UUID?
    }

    /// A recorded `editManualTransaction(id:_:)` call (ADR 0020).
    struct RecordedManualTransactionEdit: Equatable {
        let id: UUID
        let amount: Int
        let currency: String
        let valueDate: Date
        let description: String
    }

    /// A recorded `outgoingID`/`incomingID` pair, for asserting exactly which
    /// legs a confirm/reject call named.
    struct RecordedTransferPair: Equatable {
        let outgoingID: UUID
        let incomingID: UUID
    }

    /// A recorded `eventID`/`transactionID` pair, for asserting exactly which
    /// event and transaction an assign/unassign call named.
    struct RecordedEventMember: Equatable {
        let eventID: UUID
        let transactionID: UUID
    }

    // MARK: Configuration (actor-isolated setters, `await`ed from a test)

    func setAccounts(_ accounts: [AccountResponse]) {
        accountsToReturn = accounts
    }

    func setAccountsError(_ error: Error) {
        accountsError = error
    }

    func setRenameAccountResult(_ account: AccountResponse) {
        renameAccountToReturn = account
    }

    func setRenameAccountError(_ error: Error) {
        renameAccountError = error
    }

    func setAccountAppearanceResult(_ account: AccountResponse) {
        accountAppearanceToReturn = account
    }

    func setAccountAppearanceError(_ error: Error) {
        accountAppearanceError = error
    }

    func setCreateManualAccountResult(_ account: AccountResponse) {
        createManualAccountToReturn = account
    }

    func setCreateManualAccountError(_ error: Error) {
        createManualAccountError = error
    }

    func setDeleteAccountError(_ error: Error) {
        deleteAccountError = error
    }

    func setCreateManualTransactionResult(_ transaction: TransactionResponse) {
        createManualTransactionToReturn = transaction
    }

    func setCreateManualTransactionError(_ error: Error) {
        createManualTransactionError = error
    }

    func setEditManualTransactionResult(_ transaction: TransactionResponse) {
        editManualTransactionToReturn = transaction
    }

    func setEditManualTransactionError(_ error: Error) {
        editManualTransactionError = error
    }

    func setDeleteManualTransactionError(_ error: Error) {
        deleteManualTransactionError = error
    }

    func setHealthError(_ error: Error) {
        healthError = error
    }

    func setDashboardSummaryResult(_ summary: DashboardSummaryResponse) {
        dashboardSummaryToReturn = summary
    }

    func setDashboardSummaryError(_ error: Error) {
        dashboardSummaryError = error
    }

    func setTransaction(_ transaction: TransactionResponse) {
        transactionToReturn = transaction
    }

    func setTransactionError(_ error: Error) {
        transactionError = error
    }

    func setConfirmCategoryError(_ error: Error) {
        confirmCategoryError = error
    }

    func setClearCategoryError(_ error: Error) {
        clearCategoryError = error
    }

    func setCategories(_ categories: [CategoryResponse]) {
        categoriesToReturn = categories
    }

    func setCategoriesError(_ error: Error) {
        categoriesError = error
    }

    func setSeedDefaultCategoriesResult(_ categories: [CategoryResponse]) {
        seedDefaultCategoriesToReturn = categories
    }

    func setSeedDefaultCategoriesError(_ error: Error) {
        seedDefaultCategoriesError = error
    }

    func setCreateCategoryResult(_ category: CategoryResponse) {
        createCategoryToReturn = category
    }

    func setCreateCategoryError(_ error: Error) {
        createCategoryError = error
    }

    func setRenameCategoryResult(_ category: CategoryResponse) {
        renameCategoryToReturn = category
    }

    func setRenameCategoryError(_ error: Error) {
        renameCategoryError = error
    }

    func setDeleteCategoryError(_ error: Error) {
        deleteCategoryError = error
    }

    func setCategoryAppearanceResult(_ category: CategoryResponse) {
        categoryAppearanceToReturn = category
    }

    func setCategoryAppearanceError(_ error: Error) {
        categoryAppearanceError = error
    }

    func setMoveCategoryResult(_ category: CategoryResponse) {
        moveCategoryToReturn = category
    }

    func setMoveCategoryError(_ error: Error) {
        moveCategoryError = error
    }

    func setRules(_ rules: [RuleResponse]) {
        rulesToReturn = rules
    }

    func setRulesError(_ error: Error) {
        rulesError = error
    }

    func setCreateRuleResult(_ rule: RuleResponse) {
        createRuleToReturn = rule
    }

    func setCreateRuleError(_ error: Error) {
        createRuleError = error
    }

    func setDeleteRuleError(_ error: Error) {
        deleteRuleError = error
    }

    func setApplyRulesResult(_ result: ApplyRulesResponse) {
        applyRulesToReturn = result
    }

    func setApplyRulesError(_ error: Error) {
        applyRulesError = error
    }

    func setTransactions(_ transactions: [TransactionResponse]) {
        transactionsToReturn = transactions
    }

    /// Configure `transaction(id:)`'s answer for one specific id, distinct
    /// from the catch-all `setTransaction(_:)`. Needed wherever a test fetches
    /// two different rows by id (both legs of a transfer).
    func setTransaction(_ transaction: TransactionResponse, forID id: UUID) {
        transactionsByID[id] = transaction
    }

    func setTransferSuggestions(_ suggestions: [TransferSuggestionResponse]) {
        transferSuggestionsToReturn = suggestions
    }

    func setTransferSuggestionsError(_ error: Error) {
        transferSuggestionsError = error
    }

    func setTransfers(_ transfers: [TransferResponse]) {
        transfersToReturn = transfers
    }

    func setConfirmTransferResult(_ transfer: TransferResponse) {
        confirmTransferToReturn = transfer
    }

    func setConfirmTransferError(_ error: Error) {
        confirmTransferError = error
    }

    func setRejectTransferError(_ error: Error) {
        rejectTransferError = error
    }

    func setDeleteTransferError(_ error: Error) {
        deleteTransferError = error
    }

    func setAdvance(_ advance: AdvanceResponse) {
        advanceToReturn = advance
    }

    func setAdvanceError(_ error: Error) {
        advanceError = error
    }

    func setCreateAdvanceResult(_ advance: AdvanceResponse) {
        createAdvanceToReturn = advance
    }

    func setCreateAdvanceError(_ error: Error) {
        createAdvanceError = error
    }

    func setDeleteAdvanceError(_ error: Error) {
        deleteAdvanceError = error
    }

    func setWriteOffAdvanceResult(_ advance: AdvanceResponse) {
        writeOffAdvanceToReturn = advance
    }

    func setWriteOffAdvanceError(_ error: Error) {
        writeOffAdvanceError = error
    }

    func setReopenAdvanceResult(_ advance: AdvanceResponse) {
        reopenAdvanceToReturn = advance
    }

    func setReopenAdvanceError(_ error: Error) {
        reopenAdvanceError = error
    }

    func setCreateReimbursementResult(_ reimbursement: ReimbursementResponse) {
        createReimbursementToReturn = reimbursement
    }

    func setCreateReimbursementError(_ error: Error) {
        createReimbursementError = error
    }

    func setDeleteReimbursementError(_ error: Error) {
        deleteReimbursementError = error
    }

    func setReimbursements(_ reimbursements: [ReimbursementResponse]) {
        reimbursementsToReturn = reimbursements
    }

    func setReimbursementsError(_ error: Error) {
        reimbursementsError = error
    }

    func setEvents(_ events: [EventResponse]) {
        eventsToReturn = events
    }

    func setEventsError(_ error: Error) {
        eventsError = error
    }

    func setEvent(_ event: EventResponse) {
        eventToReturn = event
    }

    func setEventError(_ error: Error) {
        eventError = error
    }

    func setEventTransactions(_ transactions: [TransactionResponse]) {
        eventTransactionsToReturn = transactions
    }

    func setEventTransactionsError(_ error: Error) {
        eventTransactionsError = error
    }

    func setCreateEventResult(_ event: EventResponse) {
        createEventToReturn = event
    }

    func setCreateEventError(_ error: Error) {
        createEventError = error
    }

    func setDeleteEventError(_ error: Error) {
        deleteEventError = error
    }

    func setCloseEventResult(_ event: EventResponse) {
        closeEventToReturn = event
    }

    func setCloseEventError(_ error: Error) {
        closeEventError = error
    }

    func setReopenEventResult(_ event: EventResponse) {
        reopenEventToReturn = event
    }

    func setReopenEventError(_ error: Error) {
        reopenEventError = error
    }

    func setAssignTransactionError(_ error: Error) {
        assignTransactionError = error
    }

    func setUnassignTransactionError(_ error: Error) {
        unassignTransactionError = error
    }

    func setInstitutions(_ institutions: [InstitutionResponse]) {
        institutionsToReturn = institutions
    }

    func setInstitutionsError(_ error: Error) {
        institutionsError = error
    }

    func setStartConnectionResult(_ result: StartConnectionResponse) {
        startConnectionToReturn = result
    }

    func setStartConnectionError(_ error: Error) {
        startConnectionError = error
    }

    // MARK: APIClientProtocol

    func accounts() async throws -> [AccountResponse] {
        if let accountsError { throw accountsError }
        return accountsToReturn
    }

    func renameAccount(id: UUID, alias: String?) async throws -> AccountResponse {
        if let renameAccountError { throw renameAccountError }
        renamedAccounts.append(RecordedAccountRename(id: id, alias: alias))
        guard let renameAccountToReturn else { throw NotConfigured() }
        return renameAccountToReturn
    }

    func setAccountAppearance(
        id: UUID, color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse {
        if let accountAppearanceError { throw accountAppearanceError }
        accountAppearanceUpdates.append(RecordedAccountAppearance(id: id, color: color, icon: icon))
        guard let accountAppearanceToReturn else { throw NotConfigured() }
        return accountAppearanceToReturn
    }

    func createManualAccount(
        alias: String, kind: AccountKind, currency: String,
        color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse {
        if let createManualAccountError { throw createManualAccountError }
        createdManualAccounts.append(
            RecordedManualAccountCreate(
                alias: alias, kind: kind, currency: currency, color: color, icon: icon
            )
        )
        guard let createManualAccountToReturn else { throw NotConfigured() }
        return createManualAccountToReturn
    }

    func deleteAccount(id: UUID) async throws {
        if let deleteAccountError { throw deleteAccountError }
        deletedAccountIDs.append(id)
    }

    func createManualTransaction(
        _ request: CreateManualTransactionRequest
    ) async throws -> TransactionResponse {
        if let createManualTransactionError { throw createManualTransactionError }
        createdManualTransactions.append(
            RecordedManualTransactionCreate(
                accountID: request.accountID,
                amount: request.amount,
                currency: request.currency,
                valueDate: request.valueDate,
                description: request.description,
                confirmedCategoryID: request.confirmedCategoryID
            )
        )
        guard let createManualTransactionToReturn else { throw NotConfigured() }
        return createManualTransactionToReturn
    }

    func editManualTransaction(
        id: UUID, _ request: EditManualTransactionRequest
    ) async throws -> TransactionResponse {
        if let editManualTransactionError { throw editManualTransactionError }
        editedManualTransactions.append(
            RecordedManualTransactionEdit(
                id: id,
                amount: request.amount,
                currency: request.currency,
                valueDate: request.valueDate,
                description: request.description
            )
        )
        guard let editManualTransactionToReturn else { throw NotConfigured() }
        return editManualTransactionToReturn
    }

    func deleteManualTransaction(id: UUID) async throws {
        if let deleteManualTransactionError { throw deleteManualTransactionError }
        deletedManualTransactionIDs.append(id)
    }

    func health() async throws -> HealthResponse {
        if let healthError { throw healthError }
        return healthToReturn
    }

    func dashboardSummary(
        start: Date?, end: Date?, granularity: BucketGranularity, tz: String?,
        compareStart: Date?, compareEnd: Date?
    ) async throws -> DashboardSummaryResponse {
        receivedDashboardSummaryRequests.append((start, end, granularity, tz, compareStart, compareEnd))
        if let dashboardSummaryError { throw dashboardSummaryError }
        return dashboardSummaryToReturn
    }

    func transaction(id: UUID) async throws -> TransactionResponse {
        transactionFetchCount += 1
        if let transactionError { throw transactionError }
        if let byID = transactionsByID[id] { return byID }
        guard let transactionToReturn else { throw NotConfigured() }
        return transactionToReturn
    }

    func confirmCategory(transactionID: UUID, categoryID: UUID) async throws {
        if let confirmCategoryError { throw confirmCategoryError }
        confirmedCategoryIDs.append(categoryID)
    }

    func clearCategory(transactionID: UUID) async throws {
        if let clearCategoryError { throw clearCategoryError }
        clearCategoryCallCount += 1
    }

    func transactions(filter: TransactionFilter, limit: Int, offset: Int) async throws
        -> [TransactionResponse]
    {
        receivedTransactionsFilters.append(filter)
        receivedTransactionsOffsets.append(offset)
        return transactionsToReturn
    }

    func categories() async throws -> [CategoryResponse] {
        if let categoriesError { throw categoriesError }
        return categoriesToReturn
    }

    func seedDefaultCategories() async throws -> [CategoryResponse] {
        if let seedDefaultCategoriesError { throw seedDefaultCategoriesError }
        return seedDefaultCategoriesToReturn
    }

    func createCategory(
        name: String, parentID: UUID?, color: PaletteColor?, icon: CategoryIcon?
    ) async throws -> CategoryResponse {
        if let createCategoryError { throw createCategoryError }
        createdCategoryNames.append(name)
        createCategoryRequests.append(
            RecordedCategoryCreate(name: name, parentID: parentID, color: color, icon: icon)
        )
        guard let createCategoryToReturn else { throw NotConfigured() }
        return createCategoryToReturn
    }

    func renameCategory(id: UUID, name: String) async throws -> CategoryResponse {
        if let renameCategoryError { throw renameCategoryError }
        renamedCategories.append(RecordedRename(id: id, name: name))
        guard let renameCategoryToReturn else { throw NotConfigured() }
        return renameCategoryToReturn
    }

    func setCategoryAppearance(
        id: UUID, color: PaletteColor, icon: CategoryIcon?
    ) async throws -> CategoryResponse {
        if let categoryAppearanceError { throw categoryAppearanceError }
        categoryAppearanceUpdates.append(RecordedCategoryAppearance(id: id, color: color, icon: icon))
        guard let categoryAppearanceToReturn else { throw NotConfigured() }
        return categoryAppearanceToReturn
    }

    func moveCategory(id: UUID, parentID: UUID?) async throws -> CategoryResponse {
        if let moveCategoryError { throw moveCategoryError }
        movedCategories.append(RecordedCategoryMove(id: id, parentID: parentID))
        guard let moveCategoryToReturn else { throw NotConfigured() }
        return moveCategoryToReturn
    }

    func deleteCategory(id: UUID) async throws {
        if let deleteCategoryError { throw deleteCategoryError }
        deletedCategoryIDs.append(id)
    }

    func rules() async throws -> [RuleResponse] {
        rulesFetchCount += 1
        if let rulesError { throw rulesError }
        return rulesToReturn
    }

    func createRule(_ request: CreateRuleRequest) async throws -> RuleResponse {
        if let createRuleError { throw createRuleError }
        createdRuleRequests.append(request)
        guard let createRuleToReturn else { throw NotConfigured() }
        return createRuleToReturn
    }

    func deleteRule(id: UUID) async throws {
        if let deleteRuleError { throw deleteRuleError }
        deletedRuleIDs.append(id)
    }

    func applyRules() async throws -> ApplyRulesResponse {
        applyRulesCallCount += 1
        if let applyRulesError { throw applyRulesError }
        return applyRulesToReturn
    }

    func advances() async throws -> [AdvanceResponse] {
        advancesToReturn
    }

    func advance(id: UUID) async throws -> AdvanceResponse {
        if let advanceError { throw advanceError }
        guard let advanceToReturn else { throw NotConfigured() }
        return advanceToReturn
    }

    func createAdvance(_ request: CreateAdvanceRequest) async throws -> AdvanceResponse {
        if let createAdvanceError { throw createAdvanceError }
        createdAdvanceRequests.append(request)
        guard let createAdvanceToReturn else { throw NotConfigured() }
        return createAdvanceToReturn
    }

    func deleteAdvance(id: UUID) async throws {
        if let deleteAdvanceError { throw deleteAdvanceError }
        deletedAdvanceIDs.append(id)
    }

    func writeOffAdvance(id: UUID) async throws -> AdvanceResponse {
        writeOffAdvanceCallCount += 1
        if let writeOffAdvanceError { throw writeOffAdvanceError }
        guard let writeOffAdvanceToReturn else { throw NotConfigured() }
        return writeOffAdvanceToReturn
    }

    func reopenAdvance(id: UUID) async throws -> AdvanceResponse {
        reopenAdvanceCallCount += 1
        if let reopenAdvanceError { throw reopenAdvanceError }
        guard let reopenAdvanceToReturn else { throw NotConfigured() }
        return reopenAdvanceToReturn
    }

    func createReimbursement(
        advanceID: UUID, _ request: CreateReimbursementRequest
    ) async throws -> ReimbursementResponse {
        if let createReimbursementError { throw createReimbursementError }
        createdReimbursementRequests.append(request)
        guard let createReimbursementToReturn else { throw NotConfigured() }
        return createReimbursementToReturn
    }

    func reimbursements(advanceID: UUID) async throws -> [ReimbursementResponse] {
        if let reimbursementsError { throw reimbursementsError }
        return reimbursementsToReturn
    }

    func deleteReimbursement(advanceID: UUID, id: UUID) async throws {
        if let deleteReimbursementError { throw deleteReimbursementError }
        deletedReimbursementIDs.append(id)
    }

    func connections() async throws -> [ConnectionResponse] {
        connectionsToReturn
    }

    func institutions(country: String) async throws -> [InstitutionResponse] {
        receivedInstitutionsCountries.append(country)
        if let institutionsError { throw institutionsError }
        return institutionsToReturn
    }

    func startConnection(
        institution: String, country: String, logo: String?
    ) async throws -> StartConnectionResponse {
        startedConnections.append(
            RecordedStartConnection(institution: institution, country: country, logo: logo)
        )
        if let startConnectionError { throw startConnectionError }
        return startConnectionToReturn
    }

    func syncConnection(connectionID: UUID) async throws -> SyncResponse {
        syncConnectionToReturn
    }

    func reauthorizeConnection(connectionID: UUID) async throws -> StartConnectionResponse {
        reauthorizeConnectionToReturn
    }

    func transferSuggestions() async throws -> [TransferSuggestionResponse] {
        if let transferSuggestionsError { throw transferSuggestionsError }
        return transferSuggestionsToReturn
    }

    func transfers() async throws -> [TransferResponse] {
        transfersToReturn
    }

    func confirmTransfer(outgoingID: UUID, incomingID: UUID) async throws -> TransferResponse {
        if let confirmTransferError { throw confirmTransferError }
        confirmedTransferPairs.append(RecordedTransferPair(outgoingID: outgoingID, incomingID: incomingID))
        guard let confirmTransferToReturn else { throw NotConfigured() }
        return confirmTransferToReturn
    }

    func rejectTransfer(outgoingID: UUID, incomingID: UUID) async throws {
        if let rejectTransferError { throw rejectTransferError }
        rejectedTransferPairs.append(RecordedTransferPair(outgoingID: outgoingID, incomingID: incomingID))
    }

    func deleteTransfer(id: UUID) async throws {
        if let deleteTransferError { throw deleteTransferError }
        deletedTransferIDs.append(id)
    }

    func events() async throws -> [EventResponse] {
        eventsFetchCount += 1
        if let eventsError { throw eventsError }
        return eventsToReturn
    }

    func event(id: UUID) async throws -> EventResponse {
        eventFetchCount += 1
        if let eventError { throw eventError }
        guard let eventToReturn else { throw NotConfigured() }
        return eventToReturn
    }

    func eventTransactions(id: UUID) async throws -> [TransactionResponse] {
        eventTransactionsFetchCount += 1
        if let eventTransactionsError { throw eventTransactionsError }
        return eventTransactionsToReturn
    }

    func createEvent(_ request: CreateEventRequest) async throws -> EventResponse {
        if let createEventError { throw createEventError }
        createdEventRequests.append(request)
        guard let createEventToReturn else { throw NotConfigured() }
        return createEventToReturn
    }

    func deleteEvent(id: UUID) async throws {
        if let deleteEventError { throw deleteEventError }
        deletedEventIDs.append(id)
    }

    func closeEvent(id: UUID) async throws -> EventResponse {
        closeEventCallCount += 1
        if let closeEventError { throw closeEventError }
        guard let closeEventToReturn else { throw NotConfigured() }
        return closeEventToReturn
    }

    func reopenEvent(id: UUID) async throws -> EventResponse {
        reopenEventCallCount += 1
        if let reopenEventError { throw reopenEventError }
        guard let reopenEventToReturn else { throw NotConfigured() }
        return reopenEventToReturn
    }

    func assignTransaction(eventID: UUID, transactionID: UUID) async throws {
        if let assignTransactionError { throw assignTransactionError }
        assignedEventMembers.append(RecordedEventMember(eventID: eventID, transactionID: transactionID))
    }

    func unassignTransaction(eventID: UUID, transactionID: UUID) async throws {
        if let unassignTransactionError { throw unassignTransactionError }
        unassignedEventMembers.append(RecordedEventMember(eventID: eventID, transactionID: transactionID))
    }
}

/// A generic failure for error-injection tests that don't care about the
/// specific `APIError` shape — just that `catch` is reached.
struct FakeAPIError: Error {}
