import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `TransactionsViewModel`: `replace(_:)` — the refresh path
/// `TransactionDetailView` uses after a write, which must update one row
/// without disturbing pagination or the rest of the list — and `load()`'s
/// transfer-suggestion count and per-leg transfer lookup. Fixtures are
/// synthetic (`docs/engineering.md`).
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
            id: UUID(), transactionID: transactionID,
            description: "TEST MERCHANT 01", displayDescription: nil, bookedAt: nil,
            ownShare: 1800, receivable: 3600,
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

    @Test func applyFilterReloadsOnlyThePageNotTheContext() async throws {
        // A filter change costs exactly one request — the page. The context
        // (categories, accounts, suggestions, …) does not depend on the
        // filter (backlog task 1e, ADR 0025).
        let client = FakeAPIClient()
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()
        let pageFetchesAfterLoad = await client.receivedTransactionsFilters.count
        let suggestionFetchesAfterLoad = await client.transferSuggestionsFetchCount

        await model.applyFilter(TransactionFilter(accountID: UUID()))
        await model.applyFilter(TransactionFilter(category: .uncategorized))

        #expect(await client.receivedTransactionsFilters.count == pageFetchesAfterLoad + 2)
        #expect(await client.transferSuggestionsFetchCount == suggestionFetchesAfterLoad)
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
        outgoingID: UUID, incomingID: UUID, kind: TransferKind = .twoSided
    ) -> TransferResponse {
        TransferResponse(
            id: UUID(), kind: kind, outgoingTransactionID: outgoingID,
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
        let account = UUID()
        let a = Self.makeLeg(accountID: account, amount: -5000)
        let b = Self.makeLeg(accountID: account, amount: 5000)  // same account
        let client = FakeAPIClient()
        await client.setTransactions([a, b])
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()
        model.enterSelection()
        model.toggleSelection(a.id)
        model.toggleSelection(b.id)

        #expect(!model.canLinkSelection)
        #expect(!model.canLinkAsTwoSided)
        #expect(!model.canLinkAsFundedPaymentSelection)
    }

    @Test func canLinkAsFundedPaymentSelectionIsTrueForATwoOutflowPair() async throws {
        let a = Self.makeLeg(amount: -2500)
        let b = Self.makeLeg(amount: -5000)  // same sign, different accounts
        let client = FakeAPIClient()
        await client.setTransactions([a, b])
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()
        model.enterSelection()
        model.toggleSelection(a.id)
        model.toggleSelection(b.id)

        #expect(model.canLinkSelection)
        #expect(model.canLinkAsFundedPaymentSelection)
        #expect(!model.canLinkAsTwoSided)
    }

    @Test func linkSelectedAsFundedPaymentConfirmsWithTheChosenFundingLeg() async throws {
        let funding = Self.makeLeg(amount: -2500)  // e.g. the Revolut top-up
        let funded = Self.makeLeg(amount: -5000)  // e.g. the PayPal payment
        let client = FakeAPIClient()
        await client.setTransactions([funded, funding])  // list order irrelevant
        await client.setConfirmTransferResult(
            Self.makeTransfer(outgoingID: funding.id, incomingID: funded.id, kind: .fundedPayment)
        )
        await client.setTransaction(
            Self.makeLeg(id: funding.id, amount: -2500, role: .funding), forID: funding.id
        )
        await client.setTransaction(
            Self.makeLeg(id: funded.id, amount: -5000, role: .personal), forID: funded.id
        )
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        model.enterSelection()
        model.toggleSelection(funded.id)
        model.toggleSelection(funding.id)
        #expect(model.canLinkAsFundedPaymentSelection)

        let ok = await model.linkSelectedAsFundedPayment(fundingID: funding.id)

        #expect(ok)
        #expect(!model.isSelecting)
        #expect(model.successTick == 1)
        let recorded = await client.confirmedTransferPairs
        #expect(
            recorded == [
                .init(outgoingID: funding.id, incomingID: funded.id, kind: .fundedPayment)
            ])
        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.first { $0.id == funding.id }?.role == .funding)
        #expect(rows.first { $0.id == funded.id }?.role == .personal)
        #expect(model.transfersByTransactionID[funding.id] != nil)
        #expect(model.transfersByTransactionID[funded.id] != nil)
    }

    @Test func linkSelectedAsFundedPaymentOn422SurfacesNotLinkableAndKeepsSelection() async throws {
        let funding = Self.makeLeg(amount: -2500)
        let funded = Self.makeLeg(amount: -5000)
        let client = FakeAPIClient()
        await client.setTransactions([funding, funded])
        await client.setConfirmTransferError(APIError.badStatus(422))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()
        model.enterSelection()
        model.toggleSelection(funding.id)
        model.toggleSelection(funded.id)

        let ok = await model.linkSelectedAsFundedPayment(fundingID: funding.id)

        #expect(!ok)
        #expect(model.linkFailure == .notLinkable)
        #expect(model.isSelecting)
        #expect(model.selectedIDs.count == 2)
    }

    // MARK: Row actions — category (docs/decisions/0036-movimenti-row-actions.md)

    private static let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func confirmCategorySucceedsRefetchesAndReplacesTheRow() async throws {
        let original = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setTransaction(Self.makeTransaction(id: original.id, confirmedCategoryID: Self.categoryID))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.confirmCategory(Self.categoryID, for: original.id)

        #expect(ok)
        #expect(model.rowActionFailure == nil)
        #expect(await client.confirmedCategoryIDs == [Self.categoryID])
        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.first?.confirmedCategoryID == Self.categoryID)
    }

    @Test func confirmCategorySuccessBumpsSuccessTick() async throws {
        let original = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setTransaction(Self.makeTransaction(id: original.id, confirmedCategoryID: Self.categoryID))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        await model.confirmCategory(Self.categoryID, for: original.id)

        #expect(model.successTick == 1)
    }

    @Test func confirmCategoryFailureLeavesTheRowUnchangedAndRecordsGeneric() async throws {
        let original = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setConfirmCategoryError(FakeAPIError())
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.confirmCategory(Self.categoryID, for: original.id)

        #expect(!ok)
        #expect(model.rowActionFailure == .generic)
        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.first?.confirmedCategoryID == nil)
    }

    @Test func clearCategorySucceedsRefetchesAndReplacesTheRow() async throws {
        let original = Self.makeTransaction(confirmedCategoryID: Self.categoryID)
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setTransaction(Self.makeTransaction(id: original.id, confirmedCategoryID: nil))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.clearCategory(for: original.id)

        #expect(ok)
        #expect(await client.clearCategoryCallCount == 1)
        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.first?.confirmedCategoryID == nil)
    }

    @Test func clearCategoryFailureRecordsGeneric() async throws {
        let original = Self.makeTransaction(confirmedCategoryID: Self.categoryID)
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setClearCategoryError(FakeAPIError())
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.clearCategory(for: original.id)

        #expect(!ok)
        #expect(model.rowActionFailure == .generic)
    }

    @Test func seedDefaultCategoriesPublishesTheReturnedSetWithoutBumpingSuccessTick() async throws {
        let client = FakeAPIClient()
        let defaults = [
            CategoryResponse(
                id: UUID(), name: "TEST CATEGORY", parentID: nil, color: .slate, icon: nil,
                createdAt: Date()
            )
        ]
        await client.setSeedDefaultCategoriesResult(defaults)
        let model = TransactionsViewModel(client: client, pageSize: 50)

        let ok = await model.seedDefaultCategories()

        #expect(ok)
        #expect(model.categories.map(\.id) == defaults.map(\.id))
        #expect(model.categoriesByID.keys.sorted() == defaults.map(\.id).sorted())
        #expect(model.rowActionFailure == nil)
        // Seeding a fresh database's defaults isn't itself a write worth a
        // success haptic — only the confirm/clear/create-rule it unblocks is.
        #expect(model.successTick == 0)
    }

    @Test func seedDefaultCategoriesFailureRecordsGeneric() async throws {
        let client = FakeAPIClient()
        await client.setSeedDefaultCategoriesError(FakeAPIError())
        let model = TransactionsViewModel(client: client, pageSize: 50)

        let ok = await model.seedDefaultCategories()

        #expect(!ok)
        #expect(model.rowActionFailure == .generic)
    }

    @Test func createRuleAndApplyRulesSucceedsAndBumpsSuccessTick() async throws {
        let client = FakeAPIClient()
        let createdRule = RuleResponse(
            id: UUID(), categoryID: Self.categoryID, matchKind: .contains, pattern: "TEST MERCHANT 01",
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
        await client.setCreateRuleResult(createdRule)
        let model = TransactionsViewModel(client: client, pageSize: 50)

        let ok = await model.createRuleAndApplyRules(
            categoryID: Self.categoryID, matchKind: .contains, pattern: "TEST MERCHANT 01"
        )

        #expect(ok)
        #expect(model.rowActionFailure == nil)
        #expect(model.successTick == 1)
        #expect(await client.applyRulesCallCount == 1)
    }

    @Test func createRuleAndApplyRulesDuplicateSetsDuplicateRuleAndNeverAppliesRules() async throws {
        let client = FakeAPIClient()
        await client.setCreateRuleError(APIError.badStatus(409))
        let model = TransactionsViewModel(client: client, pageSize: 50)

        let ok = await model.createRuleAndApplyRules(
            categoryID: Self.categoryID, matchKind: .contains, pattern: "TEST MERCHANT 01"
        )

        #expect(!ok)
        #expect(model.rowActionFailure == .duplicateRule)
        #expect(model.successTick == 0)
        #expect(await client.applyRulesCallCount == 0)
    }

    @Test func createRuleAndApplyRulesGenericFailureNeverBumpsSuccessTick() async throws {
        let client = FakeAPIClient()
        await client.setCreateRuleError(FakeAPIError())
        let model = TransactionsViewModel(client: client, pageSize: 50)

        let ok = await model.createRuleAndApplyRules(
            categoryID: Self.categoryID, matchKind: .contains, pattern: "TEST MERCHANT 01"
        )

        #expect(!ok)
        #expect(model.rowActionFailure == .generic)
        #expect(model.successTick == 0)
    }

    // MARK: Row actions — mark as advance, manual edit/delete (ADR 0020)

    @Test func createAdvanceSucceedsRefetchesReplacesTheRowAndUpdatesTheAdvanceMap() async throws {
        let original = Self.makeTransaction()
        let created = Self.makeAdvance(transactionID: original.id)
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setCreateAdvanceResult(created)
        await client.setTransaction(Self.makeTransaction(id: original.id))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.createAdvance(
            ownShare: 1800, participants: [ParticipantRequest(name: "Marco", expectedAmount: 1800)],
            for: original.id
        )

        #expect(ok)
        #expect(model.rowActionFailure == nil)
        #expect(model.successTick == 1)
        #expect(model.advancesByTransactionID[original.id]?.id == created.id)
        let recorded = await client.createdAdvanceRequests
        #expect(recorded.count == 1)
    }

    @Test func createAdvanceFailureRecordsGenericAndNeverUpdatesTheAdvanceMap() async throws {
        let original = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setCreateAdvanceError(FakeAPIError())
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.createAdvance(ownShare: 1800, participants: [], for: original.id)

        #expect(!ok)
        #expect(model.rowActionFailure == .generic)
        #expect(model.advancesByTransactionID[original.id] == nil)
    }

    @Test func editManualTransactionRefetchesAndReplacesTheRow() async throws {
        let original = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setEditManualTransactionResult(Self.makeTransaction(id: original.id))
        await client.setTransaction(Self.makeTransaction(id: original.id))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.editManualTransaction(
            transactionID: original.id, amount: -1600, currency: "EUR",
            valueDate: Date(timeIntervalSince1970: 1_755_000_000), description: "TEST CASH 01 v2"
        )

        #expect(ok)
        let recorded = await client.editedManualTransactions
        #expect(recorded.first?.id == original.id)
        #expect(recorded.first?.amount == -1600)
    }

    @Test func deleteManualTransactionSucceedsDropsTheRowAndBumpsSuccessTick() async throws {
        let first = Self.makeTransaction()
        let second = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([first, second])
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.deleteManualTransaction(first.id)

        #expect(ok)
        #expect(model.successTick == 1)
        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.map(\.id) == [second.id])
        let recorded = await client.deletedManualTransactionIDs
        #expect(recorded == [first.id])
    }

    @Test func deleteManualTransactionOn409SurfacesTransactionInUseAndKeepsTheRow() async throws {
        let original = Self.makeTransaction()
        let client = FakeAPIClient()
        await client.setTransactions([original])
        await client.setDeleteManualTransactionError(APIError.badStatus(409))
        let model = TransactionsViewModel(client: client, pageSize: 50)
        await model.load()

        let ok = await model.deleteManualTransaction(original.id)

        #expect(!ok)
        #expect(model.rowActionFailure == .transactionInUse)
        guard case .loaded(let rows) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.map(\.id) == [original.id])
    }

    // MARK: Row actions — selection anchor

    @Test func enterSelectionWithAnchorStartsWithThatRowAlreadySelected() async throws {
        let model = TransactionsViewModel(client: FakeAPIClient(), pageSize: 50)
        let anchor = UUID()

        model.enterSelection(anchor: anchor)

        #expect(model.isSelecting)
        #expect(model.selectedIDs == [anchor])
    }
}
