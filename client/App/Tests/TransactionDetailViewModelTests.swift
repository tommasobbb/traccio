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

    private static func makeTransaction(confirmedCategoryID: UUID? = nil) -> TransactionResponse {
        TransactionResponse(
            id: transactionID,
            accountID: UUID(),
            amount: -1000,
            effectiveAmount: -1000,
            currency: "EUR",
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: .booked,
            role: .personal,
            suggestedCategoryID: nil,
            confirmedCategoryID: confirmedCategoryID,
            effectiveCategoryID: confirmedCategoryID
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
}
