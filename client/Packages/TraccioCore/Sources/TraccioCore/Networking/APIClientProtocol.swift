import Foundation

/// The seam a view model depends on instead of the concrete `APIClient`.
///
/// Per `.claude/rules/swift.md` ("Protocols at real seams, not everywhere"):
/// the API client is the one place a caller must not know the concrete type,
/// so a view model can be tested against a fake without a network stub.
/// `Sendable`-constrained so an `@MainActor` view model can hold `any
/// APIClientProtocol` across `await` boundaries under strict concurrency.
///
/// Mirrors `APIClient`'s public surface exactly; `APIClient` conforms via the
/// extension below rather than duplicating documentation — see the concrete
/// methods for behavior.
public protocol APIClientProtocol: Sendable {
    func accounts() async throws -> [AccountResponse]
    func renameAccount(id: UUID, alias: String?) async throws -> AccountResponse
    func setAccountAppearance(
        id: UUID, color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse
    func health() async throws -> HealthResponse
    func dashboardSummary(start: Date?, end: Date?) async throws -> DashboardSummaryResponse
    func transaction(id: UUID) async throws -> TransactionResponse
    func confirmCategory(transactionID: UUID, categoryID: UUID) async throws
    func clearCategory(transactionID: UUID) async throws
    func transactions(filter: TransactionFilter, limit: Int, offset: Int) async throws
        -> [TransactionResponse]
    func categories() async throws -> [CategoryResponse]
    func seedDefaultCategories() async throws -> [CategoryResponse]
    func createCategory(name: String) async throws -> CategoryResponse
    func renameCategory(id: UUID, name: String) async throws -> CategoryResponse
    func deleteCategory(id: UUID) async throws
    func rules() async throws -> [RuleResponse]
    func createRule(_ request: CreateRuleRequest) async throws -> RuleResponse
    func deleteRule(id: UUID) async throws
    func applyRules() async throws -> ApplyRulesResponse
    func advances() async throws -> [AdvanceResponse]
    func advance(id: UUID) async throws -> AdvanceResponse
    func createAdvance(_ request: CreateAdvanceRequest) async throws -> AdvanceResponse
    func deleteAdvance(id: UUID) async throws
    func writeOffAdvance(id: UUID) async throws -> AdvanceResponse
    func reopenAdvance(id: UUID) async throws -> AdvanceResponse
    func createReimbursement(
        advanceID: UUID, _ request: CreateReimbursementRequest
    ) async throws -> ReimbursementResponse
    func reimbursements(advanceID: UUID) async throws -> [ReimbursementResponse]
    func deleteReimbursement(advanceID: UUID, id: UUID) async throws
    func connections() async throws -> [ConnectionResponse]
    func syncConnection(connectionID: UUID) async throws -> SyncResponse
    func reauthorizeConnection(connectionID: UUID) async throws -> StartConnectionResponse
    func transferSuggestions() async throws -> [TransferSuggestionResponse]
    func transfers() async throws -> [TransferResponse]
    func confirmTransfer(outgoingID: UUID, incomingID: UUID) async throws -> TransferResponse
    func rejectTransfer(outgoingID: UUID, incomingID: UUID) async throws
    func deleteTransfer(id: UUID) async throws
    func events() async throws -> [EventResponse]
    func event(id: UUID) async throws -> EventResponse
    func eventTransactions(id: UUID) async throws -> [TransactionResponse]
    func createEvent(_ request: CreateEventRequest) async throws -> EventResponse
    func deleteEvent(id: UUID) async throws
    func closeEvent(id: UUID) async throws -> EventResponse
    func reopenEvent(id: UUID) async throws -> EventResponse
    func assignTransaction(eventID: UUID, transactionID: UUID) async throws
    func unassignTransaction(eventID: UUID, transactionID: UUID) async throws
}

extension APIClient: APIClientProtocol {}
