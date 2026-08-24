import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `TransactionsViewModel`: `replace(_:)` — the refresh path
/// `TransactionDetailView` uses after a write, which must update one row
/// without disturbing pagination or the rest of the list — and `load()`'s
/// transfer-suggestion count and per-leg transfer lookup. Fixtures are
/// synthetic (`.claude/rules/data-safety.md`).
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
            effectiveCategoryID: confirmedCategoryID,
            eventID: nil
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

    @Test func loadPublishesTransferSuggestionCountAndTransfersKeyedByBothLegs() async throws {
        let outgoingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let incomingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = FakeAPIClient()
        await client.setTransferSuggestions([
            TransferSuggestionResponse(
                outgoingTransactionID: outgoingID, incomingTransactionID: incomingID,
                currency: "EUR", outgoingAmount: -1000, incomingAmount: 1000, amountDelta: 0, dayGap: 0
            )
        ])
        let transfer = TransferResponse(
            id: UUID(), outgoingTransactionID: outgoingID, incomingTransactionID: incomingID,
            createdAt: Date()
        )
        await client.setTransfers([transfer])

        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        #expect(model.transferSuggestionCount == 1)
        #expect(model.transfersByTransactionID[outgoingID]?.id == transfer.id)
        #expect(model.transfersByTransactionID[incomingID]?.id == transfer.id)
    }

    @Test func loadLeavesTransferFieldsAtDefaultsOnFailure() async throws {
        let client = FakeAPIClient()
        await client.setTransferSuggestionsError(FakeAPIError())

        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        #expect(model.transferSuggestionCount == 0)
        #expect(model.transfersByTransactionID.isEmpty)
    }

    private static func makeAdvance(transactionID: UUID) -> AdvanceResponse {
        AdvanceResponse(
            id: UUID(), transactionID: transactionID, ownShare: 1800, receivable: 3600,
            reimbursed: 0, outstanding: 3600, excess: 0, currency: "EUR", status: .open,
            participants: [], createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    @Test func updateAdvanceSetsTheEntryForATransactionID() async throws {
        let transaction = Self.makeTransaction()
        let client = FakeAPIClient()
        let model = TransactionsViewModel(client: client, pageSize: 50)

        #expect(model.advancesByTransactionID[transaction.id] == nil)

        let advance = Self.makeAdvance(transactionID: transaction.id)
        model.updateAdvance(advance, for: transaction.id)

        #expect(model.advancesByTransactionID[transaction.id]?.id == advance.id)
    }

    @Test func updateAdvanceWithNilClearsAnExistingEntry() async throws {
        let transaction = Self.makeTransaction()
        let client = FakeAPIClient()
        let model = TransactionsViewModel(client: client, pageSize: 50)
        model.updateAdvance(Self.makeAdvance(transactionID: transaction.id), for: transaction.id)

        model.updateAdvance(nil, for: transaction.id)

        #expect(model.advancesByTransactionID[transaction.id] == nil)
    }

    @Test func loadPublishesEvents() async throws {
        let event = EventResponse(
            id: UUID(), name: "TEST TRIP", startDate: nil, endDate: nil, status: .active,
            memberCount: 0, total: 0, currency: nil, createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
        let client = FakeAPIClient()
        await client.setEvents([event])

        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        #expect(model.events.map(\.id) == [event.id])
    }

    // MARK: applyFilter

    @Test func loadSendsTheDefaultNoneFilterOnTheFirstPage() async throws {
        let client = FakeAPIClient()
        let model = TransactionsViewModel(client: client, pageSize: 50)

        await model.load()

        #expect(await client.receivedTransactionsFilters == [.none])
        #expect(await client.receivedTransactionsOffsets == [0])
    }

    @Test func applyFilterSendsTheNewFilterAndResetsToTheFirstPage() async throws {
        let client = FakeAPIClient()
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let accountID = UUID()
        await model.applyFilter(TransactionFilter(accountID: accountID))

        #expect(model.filter == TransactionFilter(accountID: accountID))
        #expect(await client.receivedTransactionsFilters.last == TransactionFilter(accountID: accountID))
        #expect(await client.receivedTransactionsOffsets.last == 0)
    }

    @Test func loadMoreSendsTheActiveFilter() async throws {
        // A full first page (pageSize rows) so `loadMore()` actually fires a
        // second request rather than treating the list as already exhausted.
        let client = FakeAPIClient()
        await client.setTransactions((0..<2).map { _ in Self.makeTransaction() })
        let model = TransactionsViewModel(client: client, pageSize: 2)
        let categoryID = UUID()
        await model.applyFilter(TransactionFilter(category: .some(categoryID)))

        await model.loadMore()

        #expect(
            await client.receivedTransactionsFilters
                == [TransactionFilter(category: .some(categoryID)), TransactionFilter(category: .some(categoryID))]
        )
        #expect(await client.receivedTransactionsOffsets == [0, 2])
    }
}
