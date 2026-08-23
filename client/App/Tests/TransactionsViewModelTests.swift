import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `TransactionsViewModel.replace(_:)` — the refresh path
/// `TransactionDetailView` uses after a category action, which must update
/// one row without disturbing pagination or the rest of the list. Fixtures
/// are synthetic (`.claude/rules/data-safety.md`).
@MainActor
struct TransactionsViewModelTests {
    private static func makeTransaction(
        id: UUID = UUID(), confirmedCategoryID: UUID? = nil
    ) -> TransactionResponse {
        TransactionResponse(
            id: id,
            accountID: UUID(),
            amount: -500,
            effectiveAmount: -500,
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

    @Test func replaceSwapsOneRowPreservingOrderAndTheRest() async throws {
        let first = Self.makeTransaction()
        let second = Self.makeTransaction()
        let third = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([first, second, third])

        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let categoryID = UUID()
        let updatedSecond = Self.makeTransaction(id: second.id, confirmedCategoryID: categoryID)
        model.replace(updatedSecond)

        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded after load()")
            return
        }
        #expect(rows.map(\.id) == [first.id, second.id, third.id])
        #expect(rows[1].confirmedCategoryID == categoryID)
        #expect(rows[0].confirmedCategoryID == nil)
        #expect(rows[2].confirmedCategoryID == nil)
    }

    @Test func replaceIsANoOpForAnUnknownID() async throws {
        let known = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([known])

        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        model.replace(Self.makeTransaction())  // a different, unknown id

        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded after load()")
            return
        }
        #expect(rows.map(\.id) == [known.id])
    }
}
