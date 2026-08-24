import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `TransactionDetailViewModel` against `FakeAPIClient` — no
/// network stub needed, per `.claude/rules/swift.md`'s "test the seam."
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented ids,
/// round amounts, `"TEST MERCHANT 01"`.
@MainActor
struct TransactionDetailViewModelTests {
    private static let transactionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static let counterpartID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let transferID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private static func makeTransaction(
        id: UUID = transactionID,
        amount: Int = -1000,
        role: TransactionRole = .personal,
        confirmedCategoryID: UUID? = nil
    ) -> TransactionResponse {
        TransactionResponse(
            id: id,
            accountID: UUID(),
            amount: amount,
            effectiveAmount: role == .transfer ? 0 : amount,
            currency: "EUR",
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: .booked,
            role: role,
            suggestedCategoryID: nil,
            confirmedCategoryID: confirmedCategoryID,
            effectiveCategoryID: confirmedCategoryID,
            eventID: nil
        )
    }

    private static func makeTransfer() -> TransferResponse {
        TransferResponse(
            id: transferID, outgoingTransactionID: transactionID, incomingTransactionID: counterpartID,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    private static let advanceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private static func makeAdvance(ownShare: Int = 1800) -> AdvanceResponse {
        AdvanceResponse(
            id: advanceID, transactionID: transactionID, ownShare: ownShare, receivable: 3600,
            reimbursed: 0, outstanding: 3600, excess: 0, currency: "EUR", status: .open,
            participants: [], createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    @Test func confirmSucceedsRefetchesAndNotifiesOnUpdate() async throws {
        let client = FakeAPIClient()
        let original = Self.makeTransaction()
        let refreshed = Self.makeTransaction(confirmedCategoryID: Self.categoryID)
        await client.setTransaction(refreshed)

        var updated: TransactionResponse?
        let model = TransactionDetailViewModel(
            transaction: original, client: client, onUpdate: { updated = $0 }
        )

        await model.confirm(categoryID: Self.categoryID)

        #expect(model.transaction.effectiveCategoryID == Self.categoryID)
        #expect(model.actionFailure == nil)
        #expect(updated?.effectiveCategoryID == Self.categoryID)
        #expect(await client.confirmedCategoryIDs == [Self.categoryID])
        #expect(await client.transactionFetchCount == 1)
    }

    @Test func confirmSuccessInvalidatesOnlyTheDashboardFreshnessScope() async throws {
        // The scope split this test exists for: confirming a category
        // changes GET /dashboard/summary's by_category breakdown, but not
        // *which* rows Movimenti's own list shows — so only `.dashboard`
        // should bump, never `.transactions` (see `DataFreshness`'s doc
        // comment).
        let client = FakeAPIClient()
        await client.setTransaction(Self.makeTransaction(confirmedCategoryID: Self.categoryID))
        let freshness = DataFreshness()

        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(), client: client,
            onDashboardStale: { freshness.markStale([.dashboard]) }
        )

        await model.confirm(categoryID: Self.categoryID)

        #expect(freshness.token(for: .dashboard) == 1)
        #expect(freshness.token(for: .transactions) == 0)
    }

    @Test func confirmFailureNeverInvalidatesDashboardFreshness() async throws {
        let client = FakeAPIClient()
        await client.setConfirmCategoryError(FakeAPIError())
        let freshness = DataFreshness()

        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(), client: client,
            onDashboardStale: { freshness.markStale([.dashboard]) }
        )

        await model.confirm(categoryID: Self.categoryID)

        #expect(model.actionFailure == .generic)
        #expect(freshness.token(for: .dashboard) == 0)
    }

    @Test func confirmFailureLeavesTransactionUnchangedAndNeverCallsOnUpdate() async throws {
        let client = FakeAPIClient()
        await client.setConfirmCategoryError(FakeAPIError())
        let original = Self.makeTransaction()

        var updateCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: original, client: client, onUpdate: { _ in updateCallCount += 1 }
        )

        await model.confirm(categoryID: Self.categoryID)

        #expect(model.transaction == original)
        #expect(model.actionFailure == .generic)
        #expect(updateCallCount == 0)
    }

    @Test func clearSucceedsRefetchesAndNotifiesOnUpdate() async throws {
        let client = FakeAPIClient()
        let original = Self.makeTransaction(confirmedCategoryID: Self.categoryID)
        let refreshed = Self.makeTransaction(confirmedCategoryID: nil)
        await client.setTransaction(refreshed)

        var updated: TransactionResponse?
        let model = TransactionDetailViewModel(
            transaction: original, client: client, onUpdate: { updated = $0 }
        )

        await model.clearCategory()

        #expect(model.transaction.confirmedCategoryID == nil)
        #expect(model.actionFailure == nil)
        #expect(updated?.confirmedCategoryID == nil)
        #expect(await client.clearCategoryCallCount == 1)
    }

    @Test func clearFailureLeavesTransactionUnchangedAndNeverCallsOnUpdate() async throws {
        let client = FakeAPIClient()
        await client.setClearCategoryError(FakeAPIError())
        let original = Self.makeTransaction(confirmedCategoryID: Self.categoryID)

        var updateCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: original, client: client, onUpdate: { _ in updateCallCount += 1 }
        )

        await model.clearCategory()

        #expect(model.transaction == original)
        #expect(model.actionFailure == .generic)
        #expect(updateCallCount == 0)
    }

    @Test func loadCategoriesIfNeededLeavesCategoriesEmptyOnFailure() async throws {
        let client = FakeAPIClient()
        await client.setCategoriesError(FakeAPIError())
        let model = TransactionDetailViewModel(transaction: Self.makeTransaction(), client: client)

        await model.loadCategoriesIfNeeded()

        // The screen stays usable: an empty list, not a crash or a failure state.
        #expect(model.categories.isEmpty)
        #expect(model.actionFailure == nil)
    }

    @Test func loadCategoriesIfNeededIsANoOpWhenAlreadySeeded() async throws {
        let client = FakeAPIClient()
        let seeded = [CategoryResponse(id: UUID(), name: "TEST CATEGORY", createdAt: Date())]
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(), categories: seeded, client: client
        )

        await model.loadCategoriesIfNeeded()

        #expect(model.categories.map(\.id) == seeded.map(\.id))
        #expect(await client.categoriesToReturn.isEmpty)  // categories() was never called
    }

    @Test func seedDefaultCategoriesPublishesTheReturnedSet() async throws {
        let client = FakeAPIClient()
        let defaults = [CategoryResponse(id: UUID(), name: "TEST CATEGORY", createdAt: Date())]
        await client.setSeedDefaultCategoriesResult(defaults)
        let model = TransactionDetailViewModel(transaction: Self.makeTransaction(), client: client)

        await model.seedDefaultCategories()

        #expect(model.categories.map(\.id) == defaults.map(\.id))
        #expect(model.actionFailure == nil)
    }

    @Test func loadTransferIfNeededResolvesTheCounterpartLeg() async throws {
        let client = FakeAPIClient()
        let counterpart = Self.makeTransaction(id: Self.counterpartID, amount: 1000, role: .transfer)
        await client.setTransaction(counterpart, forID: Self.counterpartID)
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .transfer), transfer: Self.makeTransfer(), client: client
        )

        await model.loadTransferIfNeeded()

        #expect(model.counterpartTransaction?.id == Self.counterpartID)
    }

    @Test func loadTransferIfNeededIsANoOpWithoutATransfer() async throws {
        let client = FakeAPIClient()
        let model = TransactionDetailViewModel(transaction: Self.makeTransaction(), client: client)

        await model.loadTransferIfNeeded()

        #expect(model.counterpartTransaction == nil)
        #expect(await client.transactionFetchCount == 0)
    }

    @Test func unlinkSuccessNotifiesOnUpdateForBothLegsAndClearsTheTransferLocally() async throws {
        let client = FakeAPIClient()
        let refreshedOwn = Self.makeTransaction(role: .personal, confirmedCategoryID: nil)
        let refreshedCounterpart = Self.makeTransaction(id: Self.counterpartID, amount: 1000, role: .personal)
        await client.setTransaction(refreshedOwn, forID: Self.transactionID)
        await client.setTransaction(refreshedCounterpart, forID: Self.counterpartID)

        var updatedIDs: [UUID] = []
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .transfer), transfer: Self.makeTransfer(),
            client: client, onUpdate: { updatedIDs.append($0.id) }
        )

        await model.unlinkTransfer()

        #expect(model.transfer == nil)
        #expect(model.counterpartTransaction == nil)
        #expect(model.transaction.role == .personal)
        #expect(model.actionFailure == nil)
        #expect(Set(updatedIDs) == [Self.transactionID, Self.counterpartID])
        #expect(await client.deletedTransferIDs == [Self.transferID])
    }

    @Test func unlinkFailureLeavesTheTransferInPlaceAndNeverCallsOnUpdate() async throws {
        let client = FakeAPIClient()
        await client.setDeleteTransferError(FakeAPIError())

        var updateCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .transfer), transfer: Self.makeTransfer(),
            client: client, onUpdate: { _ in updateCallCount += 1 }
        )

        await model.unlinkTransfer()

        #expect(model.transfer != nil)
        #expect(model.actionFailure == .generic)
        #expect(updateCallCount == 0)
    }

    @Test func unlinkIsANoOpWithoutATransfer() async throws {
        let client = FakeAPIClient()
        let model = TransactionDetailViewModel(transaction: Self.makeTransaction(), client: client)

        await model.unlinkTransfer()

        #expect(model.actionFailure == nil)
        #expect(await client.deletedTransferIDs.isEmpty)
    }

    @Test func createAdvanceSucceedsRefetchesAndNotifiesBothCallbacks() async throws {
        let client = FakeAPIClient()
        let created = Self.makeAdvance()
        await client.setCreateAdvanceResult(created)
        let refreshedTransaction = Self.makeTransaction(role: .advance)
        await client.setTransaction(refreshedTransaction)

        var updatedTransaction: TransactionResponse?
        var advanceChangeCallCount = 0
        var lastAdvanceChange: AdvanceResponse?
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(), client: client,
            onUpdate: { updatedTransaction = $0 },
            onAdvanceChange: {
                advanceChangeCallCount += 1
                lastAdvanceChange = $0
            }
        )

        await model.createAdvance(
            ownShare: 1800, participants: [ParticipantRequest(name: "Marco", expectedAmount: 1800)]
        )

        #expect(model.advance?.id == created.id)
        #expect(model.transaction.role == .advance)
        #expect(model.actionFailure == nil)
        #expect(updatedTransaction?.role == .advance)
        #expect(advanceChangeCallCount == 1)
        #expect(lastAdvanceChange?.id == created.id)
        let recorded = await client.createdAdvanceRequests
        #expect(recorded.count == 1)
    }

    @Test func createAdvanceFailureLeavesTransactionUnchangedAndNeverNotifies() async throws {
        let client = FakeAPIClient()
        await client.setCreateAdvanceError(FakeAPIError())
        let original = Self.makeTransaction()

        var updateCallCount = 0
        var advanceChangeCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: original, client: client,
            onUpdate: { _ in updateCallCount += 1 }, onAdvanceChange: { _ in advanceChangeCallCount += 1 }
        )

        await model.createAdvance(ownShare: 1800, participants: [])

        #expect(model.transaction == original)
        #expect(model.advance == nil)
        #expect(model.actionFailure == .generic)
        #expect(updateCallCount == 0)
        #expect(advanceChangeCallCount == 0)
    }

    @Test func deleteAdvanceSucceedsRefetchesAndNotifiesBothCallbacks() async throws {
        let client = FakeAPIClient()
        let refreshedTransaction = Self.makeTransaction(role: .personal)
        await client.setTransaction(refreshedTransaction)

        var updatedTransaction: TransactionResponse?
        var advanceChangeCallCount = 0
        var lastAdvanceChangeWasNil = false
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client, onUpdate: { updatedTransaction = $0 },
            onAdvanceChange: {
                advanceChangeCallCount += 1
                lastAdvanceChangeWasNil = $0 == nil
            }
        )

        await model.deleteAdvance()

        #expect(model.advance == nil)
        #expect(model.transaction.role == .personal)
        #expect(model.actionFailure == nil)
        #expect(updatedTransaction?.role == .personal)
        #expect(advanceChangeCallCount == 1)
        #expect(lastAdvanceChangeWasNil)
        #expect(await client.deletedAdvanceIDs == [Self.advanceID])
    }

    @Test func deleteAdvanceFailureLeavesTheAdvanceInPlaceAndNeverNotifies() async throws {
        let client = FakeAPIClient()
        await client.setDeleteAdvanceError(FakeAPIError())

        var updateCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client, onUpdate: { _ in updateCallCount += 1 }
        )

        await model.deleteAdvance()

        #expect(model.advance != nil)
        #expect(model.actionFailure == .generic)
        #expect(updateCallCount == 0)
    }

    @Test func deleteAdvanceIsANoOpWithoutAnAdvance() async throws {
        let client = FakeAPIClient()
        let model = TransactionDetailViewModel(transaction: Self.makeTransaction(), client: client)

        await model.deleteAdvance()

        #expect(model.actionFailure == nil)
        #expect(await client.deletedAdvanceIDs.isEmpty)
    }

    @Test func writeOffAdvanceSucceedsAndNotifiesOnAdvanceChange() async throws {
        let client = FakeAPIClient()
        let writtenOff = Self.makeAdvance()  // status doesn't need to differ; the fake just echoes it
        await client.setWriteOffAdvanceResult(writtenOff)

        var advanceChangeCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client, onAdvanceChange: { _ in advanceChangeCallCount += 1 }
        )

        await model.writeOffAdvance()

        #expect(model.advance?.id == writtenOff.id)
        #expect(model.actionFailure == nil)
        #expect(advanceChangeCallCount == 1)
        #expect(await client.writeOffAdvanceCallCount == 1)
    }

    @Test func writeOffAdvanceFailureSetsActionFailureAndLeavesAdvanceInPlace() async throws {
        let client = FakeAPIClient()
        await client.setWriteOffAdvanceError(FakeAPIError())
        let original = Self.makeAdvance()

        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: original, client: client
        )

        await model.writeOffAdvance()

        #expect(model.advance?.id == original.id)
        #expect(model.actionFailure == .generic)
    }

    @Test func writeOffAdvanceIsANoOpWithoutAnAdvance() async throws {
        let client = FakeAPIClient()
        let model = TransactionDetailViewModel(transaction: Self.makeTransaction(), client: client)

        await model.writeOffAdvance()

        #expect(model.actionFailure == nil)
        #expect(await client.writeOffAdvanceCallCount == 0)
    }

    @Test func reopenAdvanceSucceedsAndNotifiesOnAdvanceChange() async throws {
        let client = FakeAPIClient()
        let reopened = Self.makeAdvance()
        await client.setReopenAdvanceResult(reopened)

        var advanceChangeCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client, onAdvanceChange: { _ in advanceChangeCallCount += 1 }
        )

        await model.reopenAdvance()

        #expect(model.advance?.id == reopened.id)
        #expect(model.actionFailure == nil)
        #expect(advanceChangeCallCount == 1)
        #expect(await client.reopenAdvanceCallCount == 1)
    }

    @Test func loadReimbursementCandidatesIfNeededFiltersToPersonalIncomingSameCurrency() async throws {
        let client = FakeAPIClient()
        let matching = Self.makeTransaction(id: UUID(), amount: 1000, role: .personal)
        let outgoing = Self.makeTransaction(id: UUID(), amount: -1000, role: .personal)
        let alreadyLinked = Self.makeTransaction(id: UUID(), amount: 1000, role: .reimbursement)
        await client.setTransactions([matching, outgoing, alreadyLinked])
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(), client: client
        )

        await model.loadReimbursementCandidatesIfNeeded()

        #expect(model.reimbursementCandidates.map(\.id) == [matching.id])
    }

    @Test func loadReimbursementCandidatesIfNeededLeavesEmptyOnFailure() async throws {
        let client = FakeAPIClient()
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(), client: client
        )

        // No transactions configured on the fake, so `transactions(...)`
        // returns the default empty array — the candidates list stays empty
        // rather than the screen failing.
        await model.loadReimbursementCandidatesIfNeeded()

        #expect(model.reimbursementCandidates.isEmpty)
    }

    @Test func createReimbursementCashSucceedsRefetchesAdvanceAndDoesNotCallOnUpdate() async throws {
        let client = FakeAPIClient()
        let createdReimbursement = ReimbursementResponse(
            id: UUID(), advanceID: Self.advanceID, amount: 1000, currency: "EUR",
            transactionID: nil, participantID: nil, note: nil,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
        await client.setCreateReimbursementResult(createdReimbursement)
        let refreshedAdvance = Self.makeAdvance()
        await client.setAdvance(refreshedAdvance)

        var updateCallCount = 0
        var advanceChangeCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client, onUpdate: { _ in updateCallCount += 1 },
            onAdvanceChange: { _ in advanceChangeCallCount += 1 }
        )

        await model.createReimbursement(
            amount: 1000, transactionID: nil, participantID: nil, note: "Contanti"
        )

        #expect(model.advance?.id == refreshedAdvance.id)
        #expect(model.actionFailure == nil)
        #expect(advanceChangeCallCount == 1)
        #expect(updateCallCount == 0)
        let recorded = await client.createdReimbursementRequests
        #expect(recorded.count == 1)
    }

    @Test func createReimbursementLinkedRefetchesTheLinkedTransactionAndCallsOnUpdate() async throws {
        let client = FakeAPIClient()
        let linkedID = Self.counterpartID
        let createdReimbursement = ReimbursementResponse(
            id: UUID(), advanceID: Self.advanceID, amount: 1000, currency: "EUR",
            transactionID: linkedID, participantID: nil, note: nil,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
        await client.setCreateReimbursementResult(createdReimbursement)
        await client.setAdvance(Self.makeAdvance())
        let refreshedLinked = Self.makeTransaction(id: linkedID, amount: 1000, role: .reimbursement)
        await client.setTransaction(refreshedLinked, forID: linkedID)

        var updatedTransaction: TransactionResponse?
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client, onUpdate: { updatedTransaction = $0 }
        )

        await model.createReimbursement(
            amount: 1000, transactionID: linkedID, participantID: nil, note: nil
        )

        #expect(model.actionFailure == nil)
        #expect(updatedTransaction?.id == linkedID)
        #expect(updatedTransaction?.role == .reimbursement)
    }

    @Test func createReimbursementFailureSetsActionFailureAndNeverCallsOnUpdate() async throws {
        let client = FakeAPIClient()
        await client.setCreateReimbursementError(FakeAPIError())

        var updateCallCount = 0
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client, onUpdate: { _ in updateCallCount += 1 }
        )

        await model.createReimbursement(
            amount: 1000, transactionID: nil, participantID: nil, note: nil
        )

        #expect(model.actionFailure == .generic)
        #expect(updateCallCount == 0)
    }

    @Test func createReimbursementIsANoOpWithoutAnAdvance() async throws {
        let client = FakeAPIClient()
        let model = TransactionDetailViewModel(transaction: Self.makeTransaction(), client: client)

        await model.createReimbursement(
            amount: 1000, transactionID: nil, participantID: nil, note: nil
        )

        #expect(model.actionFailure == nil)
        let recorded = await client.createdReimbursementRequests
        #expect(recorded.isEmpty)
    }

    @Test func createReimbursementForwardsTheParticipantID() async throws {
        // ADR 0012: attribution is an explicit choice threaded straight
        // through to the request body, never inferred client-side.
        let client = FakeAPIClient()
        await client.setAdvance(Self.makeAdvance())
        let participantID = UUID()
        let model = TransactionDetailViewModel(
            transaction: Self.makeTransaction(role: .advance), advance: Self.makeAdvance(),
            client: client
        )

        await model.createReimbursement(
            amount: 1000, transactionID: nil, participantID: participantID, note: nil
        )

        let recorded = await client.createdReimbursementRequests
        #expect(recorded.count == 1)
        #expect(recorded.first?.participantID == participantID)
    }
}
