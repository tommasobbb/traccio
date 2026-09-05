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
                kind: .twoSided,
                outgoingTransactionID: outgoingID, incomingTransactionID: incomingID,
                currency: "EUR", outgoingAmount: -1000, incomingAmount: 1000, amountDelta: 0, dayGap: 0,
                outgoing: Self.makeTransaction(id: outgoingID),
                incoming: Self.makeTransaction(id: incomingID)
            )
        ])
        let transfer = TransferResponse(
            id: UUID(), kind: .twoSided, outgoingTransactionID: outgoingID,
            incomingTransactionID: incomingID, createdAt: Date()
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

    // MARK: updateSearchTerm

    @Test func updateSearchTermDebouncesRapidCallsIntoOneRequest() async throws {
        let client = FakeAPIClient()
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        // Three keystrokes in quick succession, well inside the debounce
        // window — only the last should ever reach the backend.
        model.updateSearchTerm("mer")
        model.updateSearchTerm("merc")
        model.updateSearchTerm("mercato")

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(model.filter.searchTerm == "mercato")
        let filters = await client.receivedTransactionsFilters
        // load()'s own request, plus exactly one debounced applyFilter.
        #expect(filters.count == 2)
        #expect(filters.last?.searchTerm == "mercato")
    }

    // MARK: Manual movements (ADR 0020)

    private static func makeAccount(id: UUID, source: AccountSource) -> AccountResponse {
        AccountResponse(
            id: id,
            connectionID: source == .manual ? nil : UUID(),
            source: source,
            kind: source == .manual ? .cash : .current,
            currency: "EUR",
            name: source == .manual ? nil : "TEST CURRENT 01",
            alias: source == .manual ? "Contanti" : nil,
            displayName: source == .manual ? "Contanti" : "TEST CURRENT 01",
            color: nil,
            icon: nil,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    @Test func manualAccountsFiltersOutSyncedOnes() async throws {
        let manualID = UUID()
        let client = FakeAPIClient()
        await client.setAccounts([
            Self.makeAccount(id: UUID(), source: .synced),
            Self.makeAccount(id: manualID, source: .manual),
        ])
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        #expect(model.manualAccounts.map(\.id) == [manualID])
    }

    @Test func createManualTransactionReloadsAndBumpsSuccessTickOnSuccess() async throws {
        let accountID = UUID()
        let client = FakeAPIClient()
        await client.setTransactions([Self.makeTransaction()])
        await client.setCreateManualTransactionResult(Self.makeTransaction())
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.createManualTransaction(
            accountID: accountID, amount: -1500, currency: "EUR",
            valueDate: Date(timeIntervalSince1970: 1_755_000_000),
            description: "TEST CASH 01", confirmedCategoryID: nil
        )

        #expect(ok)
        #expect(model.createFailure == nil)
        #expect(model.successTick == 1)
        let recorded = await client.createdManualTransactions
        #expect(recorded.count == 1)
        #expect(recorded.first?.accountID == accountID)
        #expect(recorded.first?.amount == -1500)
        // load()'s first-page request, then a second after the create.
        #expect(await client.receivedTransactionsOffsets == [0, 0])
    }

    @Test func createManualTransactionOn409SurfacesAccountNotManual() async throws {
        let client = FakeAPIClient()
        await client.setCreateManualTransactionError(APIError.badStatus(409))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.createManualTransaction(
            accountID: UUID(), amount: -1, currency: "EUR",
            valueDate: Date(timeIntervalSince1970: 1_755_000_000),
            description: "x", confirmedCategoryID: nil
        )

        #expect(!ok)
        #expect(model.createFailure == .accountNotManual)
    }

    @Test func removeDropsOneRowLeavingTheRest() async throws {
        let first = Self.makeTransaction()
        let second = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([first, second])
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        model.remove(id: first.id)

        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.map(\.id) == [second.id])
    }

    // MARK: Free-form transfer linking (docs/domain.md §Transfer)

    private static func makeLeg(
        id: UUID = UUID(), accountID: UUID = UUID(), amount: Int, role: TransactionRole = .personal
    ) -> TransactionResponse {
        TransactionResponse(
            id: id, accountID: accountID, amount: amount,
            effectiveAmount: role == .personal ? amount : 0, currency: "EUR",
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000), valueDate: nil,
            description: "TEST MERCHANT 01", displayDescription: nil, status: .booked, role: role,
            suggestedCategoryID: nil, confirmedCategoryID: nil, effectiveCategoryID: nil, eventID: nil
        )
    }

    private static func makeTransfer(
        outgoingID: UUID, incomingID: UUID
    ) -> TransferResponse {
        TransferResponse(
            id: UUID(), kind: .twoSided, outgoingTransactionID: outgoingID,
            incomingTransactionID: incomingID,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    @Test func enterAndExitSelectionResetTheSelectionState() async throws {
        let client = FakeAPIClient()
        let model = TransactionsViewModel(client: client, pageSize: 50)

        model.enterSelection()
        #expect(model.isSelecting)
        model.toggleSelection(UUID())
        #expect(model.selectedIDs.count == 1)

        model.exitSelection()
        #expect(!model.isSelecting)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func toggleSelectionCapsAtTwoAndRemoves() async throws {
        let model = TransactionsViewModel(client: FakeAPIClient(), pageSize: 50)
        let a = UUID()
        let b = UUID()
        let c = UUID()
        model.enterSelection()

        model.toggleSelection(a)
        model.toggleSelection(b)
        model.toggleSelection(c)  // ignored — already two
        #expect(model.selectedIDs == [a, b])

        model.toggleSelection(a)  // removes
        #expect(model.selectedIDs == [b])
    }

    @Test func linkSelectedAsTransferConfirmsWithNegativeLegAsOutgoing() async throws {
        let accountA = UUID()
        let accountB = UUID()
        let outgoing = Self.makeLeg(accountID: accountA, amount: -5000)
        let incoming = Self.makeLeg(accountID: accountB, amount: 5000)
        let client = FakeAPIClient()
        await client.setTransactions([incoming, outgoing])  // list order irrelevant
        await client.setConfirmTransferResult(
            Self.makeTransfer(outgoingID: outgoing.id, incomingID: incoming.id)
        )
        await client.setTransaction(
            Self.makeLeg(id: outgoing.id, accountID: accountA, amount: -5000, role: .transfer),
            forID: outgoing.id
        )
        await client.setTransaction(
            Self.makeLeg(id: incoming.id, accountID: accountB, amount: 5000, role: .transfer),
            forID: incoming.id
        )
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        model.enterSelection()
        // Select incoming first, then outgoing — sign, not order, decides.
        model.toggleSelection(incoming.id)
        model.toggleSelection(outgoing.id)
        #expect(model.canLinkSelection)

        let ok = await model.linkSelectedAsTransfer()

        #expect(ok)
        #expect(!model.isSelecting)
        #expect(model.successTick == 1)
        let recorded = await client.confirmedTransferPairs
        #expect(recorded == [.init(outgoingID: outgoing.id, incomingID: incoming.id)])
        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.allSatisfy { $0.role == .transfer })
        #expect(model.transfersByTransactionID[outgoing.id] != nil)
        #expect(model.transfersByTransactionID[incoming.id] != nil)
    }

    @Test func linkSelectedAsTransferOn409SurfacesAlreadyLinkedAndKeepsSelection() async throws {
        let outgoing = Self.makeLeg(amount: -5000)
        let incoming = Self.makeLeg(amount: 5000)
        let client = FakeAPIClient()
        await client.setTransactions([outgoing, incoming])
        await client.setConfirmTransferError(APIError.badStatus(409))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()
        model.enterSelection()
        model.toggleSelection(outgoing.id)
        model.toggleSelection(incoming.id)

        let ok = await model.linkSelectedAsTransfer()

        #expect(!ok)
        #expect(model.linkFailure == .alreadyLinked)
        #expect(model.isSelecting)
        #expect(model.selectedIDs.count == 2)
    }

    @Test func linkSelectedAsTransferOn422SurfacesNotLinkable() async throws {
        let outgoing = Self.makeLeg(amount: -5000)
        let incoming = Self.makeLeg(amount: 5000)
        let client = FakeAPIClient()
        await client.setTransactions([outgoing, incoming])
        await client.setConfirmTransferError(APIError.badStatus(422))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()
        model.enterSelection()
        model.toggleSelection(outgoing.id)
        model.toggleSelection(incoming.id)

        _ = await model.linkSelectedAsTransfer()

        #expect(model.linkFailure == .notLinkable)
    }

    @Test func canLinkSelectionIsFalseForAnInvalidPair() async throws {
        let a = Self.makeLeg(amount: -5000)
        let b = Self.makeLeg(amount: -3000)  // same sign
        let client = FakeAPIClient()
        await client.setTransactions([a, b])
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()
        model.enterSelection()
        model.toggleSelection(a.id)
        model.toggleSelection(b.id)

        #expect(!model.canLinkSelection)
    }
}
