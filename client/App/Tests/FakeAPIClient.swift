import Foundation
import TraccioCore

/// A fake `APIClientProtocol` for view-model tests — no network stub needed.
///
/// An `actor` rather than a class with `@unchecked Sendable`:
/// `APIClientProtocol` requires `Sendable` conformance, and an actor gets that
/// for free while still letting a test configure canned responses safely
/// across `await` boundaries. Lives in the test target, not `TraccioCore`
/// (`docs/engineering.md`): a production module should not ship a fake.
///
/// Every method has a safe default (an empty collection, or a placeholder
/// value) so a test that doesn't care about a given call doesn't need to
/// configure it. Fixtures are synthetic throughout
/// (`docs/engineering.md`).
///
/// This file holds only the actor's stored state and `NotConfigured`. The
/// `Recorded*` types, the `set*` configuration methods, and the
/// `APIClientProtocol` conformance itself are split by domain across
/// `FakeAPIClient+*.swift` in this directory, mirroring `APIClient+*.swift`
/// in `TraccioCore`. Extensions cannot declare stored properties, so — unlike
/// that split, which could keep everything file-local — every property a
/// domain extension needs to read or record into has to be `internal`
/// (plain `var`) rather than `private(set)`; a test target's own fixture is
/// a lower-stakes place for that trade-off than production code.
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
    var importPreviewToReturn: ImportPreviewResponse?
    var importPreviewError: Error?
    var importCommitToReturn: ImportCommitResponse?
    var importCommitError: Error?
    var settingsToReturn = SettingsResponse(trackingStartDate: nil, mealVouchersEnabled: false)
    var settingsError: Error?
    var accountKindToReturn: AccountResponse?
    var accountKindError: Error?
    var trackingStartSuggestionToReturn: TrackingStartSuggestionResponse?
    var trackingStartSuggestionError: Error?
    var healthToReturn = HealthResponse(status: "ok", version: "test")
    var healthError: Error?
    var dashboardSummaryToReturn = DashboardSummaryResponse(currencies: [])
    var dashboardSummaryError: Error?
    /// Every `dashboardSummary` call's full argument set, in order — lets a
    /// test assert the period, granularity, time zone, and comparison window
    /// a reload actually requested.
    var receivedDashboardSummaryRequests: [
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
    var advancesSummaryToReturn = AdvancesSummaryResponse(byPerson: [], totals: [])
    var advancesError: Error?
    /// The `status` argument of the most recent `advances(status:)` call.
    var lastAdvancesStatus: AdvanceStatus??
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
    var connectionsFetchCount = 0
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
    var backfillConnectionLogosToReturn = BackfillLogosResponse(updated: 0)
    var backfillConnectionLogosError: Error?
    var backfillConnectionLogosCallCount = 0
    var transferSuggestionsToReturn: [TransferSuggestionResponse] = []
    var transferSuggestionsError: Error?
    var transferSuggestionsFetchCount = 0
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
    var eventSummaryToReturn: EventSummaryResponse?
    var eventSummaryError: Error?
    var eventSummaryFetchCount = 0
    var eventSuggestionsToReturn: [TransactionResponse] = []
    var eventSuggestionsError: Error?
    var eventSuggestionsFetchCount = 0
    var eventTransactionsError: Error?
    var createEventToReturn: EventResponse?
    var createEventError: Error?
    var updateEventToReturn: EventResponse?
    var updateEventError: Error?
    var deleteEventError: Error?
    var closeEventToReturn: EventResponse?
    var closeEventError: Error?
    var reopenEventToReturn: EventResponse?
    var reopenEventError: Error?
    var assignTransactionError: Error?
    var unassignTransactionError: Error?

    // MARK: Call recording

    var confirmedCategoryIDs: [UUID] = []
    var clearCategoryCallCount = 0
    var transactionFetchCount = 0
    /// Every `filter` the view model under test passed to `transactions(filter:limit:offset:)`,
    /// in call order — proves `TransactionsViewModel.applyFilter(_:)` and
    /// `loadMore()` send it, not just hold it.
    var receivedTransactionsFilters: [TransactionFilter] = []
    /// Every `offset` passed to `transactions(filter:limit:offset:)`, in call
    /// order — proves a filter change resets pagination to the first page.
    var receivedTransactionsOffsets: [Int] = []
    var confirmedTransferPairs: [RecordedTransferPair] = []
    var rejectedTransferPairs: [RecordedTransferPair] = []
    var deletedTransferIDs: [UUID] = []
    var createdAdvanceRequests: [CreateAdvanceRequest] = []
    var deletedAdvanceIDs: [UUID] = []
    var writeOffAdvanceCallCount = 0
    var reopenAdvanceCallCount = 0
    var createdReimbursementRequests: [CreateReimbursementRequest] = []
    var deletedReimbursementIDs: [UUID] = []
    var createdCategoryNames: [String] = []
    var createCategoryRequests: [RecordedCategoryCreate] = []
    var renamedCategories: [RecordedRename] = []
    var categoryAppearanceUpdates: [RecordedCategoryAppearance] = []
    var movedCategories: [RecordedCategoryMove] = []
    var deletedCategoryIDs: [UUID] = []
    var rulesFetchCount = 0
    var createdRuleRequests: [CreateRuleRequest] = []
    var deletedRuleIDs: [UUID] = []
    var applyRulesCallCount = 0
    var eventsFetchCount = 0
    var eventFetchCount = 0
    var eventTransactionsFetchCount = 0
    var createdEventRequests: [CreateEventRequest] = []
    var updatedEventRequests: [(id: UUID, request: UpdateEventRequest)] = []
    var deletedEventIDs: [UUID] = []
    var closeEventCallCount = 0
    var reopenEventCallCount = 0
    var assignedEventMembers: [RecordedEventMember] = []
    var unassignedEventMembers: [RecordedEventMember] = []
    var renamedAccounts: [RecordedAccountRename] = []
    var accountAppearanceUpdates: [RecordedAccountAppearance] = []
    var accountKindUpdates: [RecordedAccountKind] = []
    var createdManualAccounts: [RecordedManualAccountCreate] = []
    var deletedAccountIDs: [UUID] = []
    var createdManualTransactions: [RecordedManualTransactionCreate] = []
    var editedManualTransactions: [RecordedManualTransactionEdit] = []
    var deletedManualTransactionIDs: [UUID] = []
    var importPreviewRequests: [ImportPreviewRequest] = []
    var importCommitRequests: [ImportPreviewRequest] = []
    var setTrackingStartValues: [CalendarDate?] = []
    var setMealVouchersEnabledValues: [Bool] = []
    /// Every `country` passed to `institutions(country:)`, in call order.
    var receivedInstitutionsCountries: [String] = []
    /// Every `startConnection(institution:country:)` call, for asserting
    /// exactly which institution and country were sent.
    var startedConnections: [RecordedStartConnection] = []
}

/// A generic failure for error-injection tests that don't care about the
/// specific `APIError` shape — just that `catch` is reached.
struct FakeAPIError: Error {}
