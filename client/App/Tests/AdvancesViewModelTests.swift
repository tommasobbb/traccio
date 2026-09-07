import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `AdvancesViewModel` against `FakeAPIClient` — no network stub,
/// per `.claude/rules/swift.md`'s "test the seam." Fixtures are synthetic
/// (`.claude/rules/data-safety.md`): invented ids and names, round amounts.
@MainActor
struct AdvancesViewModelTests {
    private static let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let txID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let accountID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private static func makeAdvance(
        id: UUID = advanceID,
        transactionID: UUID = txID,
        outstanding: Int = 4000,
        status: AdvanceStatus = .open
    ) -> AdvanceResponse {
        AdvanceResponse(
            id: id,
            transactionID: transactionID,
            ownShare: 1000,
            receivable: 4000,
            reimbursed: 4000 - outstanding,
            outstanding: outstanding,
            excess: 0,
            currency: "EUR",
            status: status,
            participants: [
                ParticipantResponse(
                    id: UUID(),
                    name: "Marco",
                    expectedAmount: 4000,
                    reimbursed: 4000 - outstanding,
                    outstanding: outstanding,
                    excess: 0,
                    status: outstanding == 0 ? .settled : .outstanding
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    private static func makeTransaction(id: UUID = txID) -> TransactionResponse {
        TransactionResponse(
            id: id,
            accountID: accountID,
            amount: -5000,
            effectiveAmount: -1000,
            currency: "EUR",
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: .booked,
            role: .advance,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil,
            eventID: nil
        )
    }

    private static func makeAccount() -> AccountResponse {
        AccountResponse(
            id: accountID,
            connectionID: UUID(),
            source: .synced,
            kind: .current,
            currency: "EUR",
            name: "TEST CURRENT 01",
            alias: nil,
            displayName: "TEST CURRENT 01",
            color: nil,
            icon: nil,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    private static func summary(
        personOutstanding: Int = 4000,
        totalOutstanding: Int = 4000
    ) -> AdvancesSummaryResponse {
        AdvancesSummaryResponse(
            byPerson: [
                PersonSummaryResponse(
                    name: "Marco",
                    currency: "EUR",
                    expected: 4000,
                    reimbursed: 4000 - personOutstanding,
                    outstanding: personOutstanding,
                    advanceCount: 1
                )
            ],
            totals: [
                ReceivableTotalResponse(
                    currency: "EUR", outstanding: totalOutstanding, openAdvances: 1
                )
            ]
        )
    }

    @Test func loadPublishesRowsAndResolvesTransactions() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([Self.makeAdvance()])
        await client.setAdvancesSummary(Self.summary())
        await client.setTransaction(Self.makeTransaction(), forID: Self.txID)
        await client.setAccounts([Self.makeAccount()])
        let model = AdvancesViewModel(client: client)

        await model.load()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.response.advances.map(\.id) == [Self.advanceID])
        #expect(loaded.transactionsByID[Self.txID]?.description == "TEST MERCHANT 01")
        #expect(loaded.accountsByID[Self.accountID] != nil)
        #expect(loaded.response.summary.totals.first?.outstanding == 4000)
        #expect(loaded.hasUnattributedReimbursements == false)
    }

    @Test func statusFilterReloadsWithTheFilterAndNarrowsRows() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([
            Self.makeAdvance(id: UUID(), transactionID: UUID(), outstanding: 4000, status: .open),
            Self.makeAdvance(id: UUID(), transactionID: UUID(), outstanding: 0, status: .settled),
        ])
        await client.setAdvancesSummary(Self.summary())
        let model = AdvancesViewModel(client: client)
        await model.load()

        await model.setStatusFilter(.open)

        #expect(model.statusFilter == .open)
        #expect(await client.lastAdvancesStatus == .some(.some(.open)))
        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.response.advances.allSatisfy { $0.status == .open })
    }

    @Test func loadFailureIsSurfacedAsFailed() async throws {
        let client = FakeAPIClient()
        await client.setAdvancesError(FakeAPIError())
        let model = AdvancesViewModel(client: client)

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected .failed")
            return
        }
    }

    @Test func flagsUnattributedReimbursementsWhenPersonSumTrailsTheTotal() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([Self.makeAdvance()])
        await client.setAdvancesSummary(
            Self.summary(personOutstanding: 3000, totalOutstanding: 4000)
        )
        let model = AdvancesViewModel(client: client)

        await model.load()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.hasUnattributedReimbursements)
    }

    @Test func keepsRowWhoseTransactionDidNotResolve() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([Self.makeAdvance()])
        await client.setAdvancesSummary(Self.summary())
        // No setTransaction — transaction(id:) throws, the row survives anyway.
        let model = AdvancesViewModel(client: client)

        await model.load()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.response.advances.count == 1)
        #expect(loaded.transactionsByID.isEmpty)
    }
}
