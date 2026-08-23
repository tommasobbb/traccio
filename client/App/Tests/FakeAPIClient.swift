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
    var healthToReturn = HealthResponse(status: "ok", version: "test")
    var dashboardSummaryToReturn = DashboardSummaryResponse(currencies: [])
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
    var deleteCategoryError: Error?
    var rulesToReturn: [RuleResponse] = []
    var rulesError: Error?
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
    var connectionsToReturn: [ConnectionResponse] = []
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

    // MARK: Call recording

    private(set) var confirmedCategoryIDs: [UUID] = []
    private(set) var clearCategoryCallCount = 0
    private(set) var transactionFetchCount = 0
    private(set) var confirmedTransferPairs: [RecordedTransferPair] = []
    private(set) var rejectedTransferPairs: [RecordedTransferPair] = []
    private(set) var deletedTransferIDs: [UUID] = []
    private(set) var createdAdvanceRequests: [CreateAdvanceRequest] = []
    private(set) var deletedAdvanceIDs: [UUID] = []
    private(set) var writeOffAdvanceCallCount = 0
    private(set) var reopenAdvanceCallCount = 0
    private(set) var createdReimbursementRequests: [CreateReimbursementRequest] = []
    private(set) var createdCategoryNames: [String] = []
    private(set) var renamedCategories: [RecordedRename] = []
    private(set) var deletedCategoryIDs: [UUID] = []
    private(set) var rulesFetchCount = 0

    /// A recorded `renameCategory(id:name:)` call, for asserting exactly
    /// which category was renamed to what.
    struct RecordedRename: Equatable {
        let id: UUID
        let name: String
    }

    /// A recorded `outgoingID`/`incomingID` pair, for asserting exactly which
    /// legs a confirm/reject call named.
    struct RecordedTransferPair: Equatable {
        let outgoingID: UUID
        let incomingID: UUID
    }

    // MARK: Configuration (actor-isolated setters, `await`ed from a test)

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

    func setRules(_ rules: [RuleResponse]) {
        rulesToReturn = rules
    }

    func setRulesError(_ error: Error) {
        rulesError = error
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

    // MARK: APIClientProtocol

    func accounts() async throws -> [AccountResponse] {
        accountsToReturn
    }

    func health() async throws -> HealthResponse {
        healthToReturn
    }

    func dashboardSummary(start: Date?, end: Date?) async throws -> DashboardSummaryResponse {
        dashboardSummaryToReturn
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

    func transactions(accountID: UUID?, limit: Int, offset: Int) async throws -> [TransactionResponse] {
        transactionsToReturn
    }

    func categories() async throws -> [CategoryResponse] {
        if let categoriesError { throw categoriesError }
        return categoriesToReturn
    }

    func seedDefaultCategories() async throws -> [CategoryResponse] {
        if let seedDefaultCategoriesError { throw seedDefaultCategoriesError }
        return seedDefaultCategoriesToReturn
    }

    func createCategory(name: String) async throws -> CategoryResponse {
        if let createCategoryError { throw createCategoryError }
        createdCategoryNames.append(name)
        guard let createCategoryToReturn else { throw NotConfigured() }
        return createCategoryToReturn
    }

    func renameCategory(id: UUID, name: String) async throws -> CategoryResponse {
        if let renameCategoryError { throw renameCategoryError }
        renamedCategories.append(RecordedRename(id: id, name: name))
        guard let renameCategoryToReturn else { throw NotConfigured() }
        return renameCategoryToReturn
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
        reimbursementsToReturn
    }

    func connections() async throws -> [ConnectionResponse] {
        connectionsToReturn
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
}

/// A generic failure for error-injection tests that don't care about the
/// specific `APIError` shape — just that `catch` is reached.
struct FakeAPIError: Error {}
