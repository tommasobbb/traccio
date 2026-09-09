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
    // MARK: - Accounts
    func accounts() async throws -> [AccountResponse]
    func renameAccount(id: UUID, alias: String?) async throws -> AccountResponse
    func setAccountAppearance(
        id: UUID, color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse
    func createManualAccount(
        alias: String, kind: AccountKind, currency: String,
        color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse
    func deleteAccount(id: UUID) async throws

    // MARK: - Health
    func health() async throws -> HealthResponse

    // MARK: - Dashboard
    func dashboardSummary(
        start: Date?, end: Date?, granularity: BucketGranularity, tz: String?,
        compareStart: Date?, compareEnd: Date?
    ) async throws -> DashboardSummaryResponse

    // MARK: - Transactions
    func transaction(id: UUID) async throws -> TransactionResponse
    func confirmCategory(transactionID: UUID, categoryID: UUID) async throws
    func clearCategory(transactionID: UUID) async throws
    func createManualTransaction(
        _ request: CreateManualTransactionRequest
    ) async throws -> TransactionResponse
    func editManualTransaction(
        id: UUID, _ request: EditManualTransactionRequest
    ) async throws -> TransactionResponse
    func deleteManualTransaction(id: UUID) async throws
    func transactions(filter: TransactionFilter, limit: Int, offset: Int) async throws
        -> [TransactionResponse]

    // MARK: - Imports
    func importPreview(_ request: ImportPreviewRequest) async throws -> ImportPreviewResponse
    func importCommit(_ request: ImportPreviewRequest) async throws -> ImportCommitResponse

    // MARK: - Settings / tracking start
    func settings() async throws -> TrackingStartResponse
    func setTrackingStart(_ date: CalendarDate?) async throws -> TrackingStartResponse
    func trackingStartSuggestion() async throws -> TrackingStartSuggestionResponse

    // MARK: - Categories
    func categories() async throws -> [CategoryResponse]
    func seedDefaultCategories() async throws -> [CategoryResponse]
    func createCategory(
        name: String, parentID: UUID?, color: PaletteColor?, icon: CategoryIcon?
    ) async throws -> CategoryResponse
    func renameCategory(id: UUID, name: String) async throws -> CategoryResponse
    func setCategoryAppearance(
        id: UUID, color: PaletteColor, icon: CategoryIcon?
    ) async throws -> CategoryResponse
    func moveCategory(id: UUID, parentID: UUID?) async throws -> CategoryResponse
    func deleteCategory(id: UUID) async throws

    // MARK: - Rules
    func rules() async throws -> [RuleResponse]
    func createRule(_ request: CreateRuleRequest) async throws -> RuleResponse
    func deleteRule(id: UUID) async throws
    func applyRules() async throws -> ApplyRulesResponse

    // MARK: - Advances & reimbursements
    func advances(status: AdvanceStatus?) async throws -> AdvancesResponse
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

    // MARK: - Connections
    func connections() async throws -> [ConnectionResponse]
    func institutions(country: String) async throws -> [InstitutionResponse]
    func startConnection(
        institution: String, country: String, logo: String?
    ) async throws -> StartConnectionResponse
    func syncConnection(connectionID: UUID) async throws -> SyncResponse
    func reauthorizeConnection(connectionID: UUID) async throws -> StartConnectionResponse
    func backfillConnectionLogos() async throws -> BackfillLogosResponse

    // MARK: - Transfers
    func transferSuggestions() async throws -> [TransferSuggestionResponse]
    func transfers() async throws -> [TransferResponse]
    func confirmTransfer(
        outgoingID: UUID, incomingID: UUID, kind: TransferKind
    ) async throws -> TransferResponse
    func rejectTransfer(outgoingID: UUID, incomingID: UUID) async throws
    func deleteTransfer(id: UUID) async throws

    // MARK: - Events
    func events() async throws -> [EventResponse]
    func event(id: UUID) async throws -> EventResponse
    func eventTransactions(id: UUID) async throws -> [TransactionResponse]
    func eventSummary(id: UUID) async throws -> EventSummaryResponse
    func eventSuggestions(id: UUID) async throws -> [TransactionResponse]
    func createEvent(_ request: CreateEventRequest) async throws -> EventResponse
    func updateEvent(id: UUID, _ request: UpdateEventRequest) async throws -> EventResponse
    func deleteEvent(id: UUID) async throws
    func closeEvent(id: UUID) async throws -> EventResponse
    func reopenEvent(id: UUID) async throws -> EventResponse
    func assignTransaction(eventID: UUID, transactionID: UUID) async throws
    func unassignTransaction(eventID: UUID, transactionID: UUID) async throws
}

extension APIClient: APIClientProtocol {}
