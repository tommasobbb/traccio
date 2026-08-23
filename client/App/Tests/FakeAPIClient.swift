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
    var transactionError: Error?
    var confirmCategoryError: Error?
    var clearCategoryError: Error?
    var transactionsToReturn: [TransactionResponse] = []
    var categoriesToReturn: [CategoryResponse] = []
    var categoriesError: Error?
    var seedDefaultCategoriesToReturn: [CategoryResponse] = []
    var seedDefaultCategoriesError: Error?
    var advancesToReturn: [AdvanceResponse] = []
    var connectionsToReturn: [ConnectionResponse] = []
    var syncConnectionToReturn = SyncResponse(accountsSynced: 0, transactionsSynced: 0)
    var reauthorizeConnectionToReturn = StartConnectionResponse(
        connectionID: UUID(), authorizationURL: "https://sca.example.test/go"
    )

    // MARK: Call recording

    private(set) var confirmedCategoryIDs: [UUID] = []
    private(set) var clearCategoryCallCount = 0
    private(set) var transactionFetchCount = 0

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

    func setTransactions(_ transactions: [TransactionResponse]) {
        transactionsToReturn = transactions
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

    func advances() async throws -> [AdvanceResponse] {
        advancesToReturn
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
}

/// A generic failure for error-injection tests that don't care about the
/// specific `APIError` shape — just that `catch` is reached.
struct FakeAPIError: Error {}
