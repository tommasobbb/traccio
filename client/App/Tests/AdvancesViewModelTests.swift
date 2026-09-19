import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `AdvancesViewModel` against `FakeAPIClient` — no network stub,
/// per `docs/engineering.md`'s "test the seam." Fixtures are synthetic
/// (`docs/engineering.md`): invented ids and names, round amounts.
@MainActor
struct AdvancesViewModelTests {
    private static let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let txID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let accountID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private static func makeAdvance(
        id: UUID = advanceID,
        transactionID: UUID = txID,
        outstanding: Int = 4000,
        status: AdvanceStatus = .open,
        participantName: String = "Marco",
        participantKey: String = "marco"
    ) -> AdvanceResponse {
        AdvanceResponse(
            id: id,
            transactionID: transactionID,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
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
                    name: participantName,
                    personKey: participantKey,
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
                    personKey: "marco",
                    currency: "EUR",
                    expected: 4000,
                    reimbursed: 4000 - personOutstanding,
                    outstanding: personOutstanding,
                    advanceCount: 1
                )
            ],
            totals: [
                ReceivableTotalResponse(
                    currency: "EUR", outstanding: totalOutstanding, expected: 4000,
                    reimbursed: 4000 - totalOutstanding, openAdvances: 1
                )
            ]
        )
    }

    @Test func loadPublishesRowsFromTheResponseWithNoPerAdvanceFetch() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([Self.makeAdvance()])
        await client.setAdvancesSummary(Self.summary())
        let model = AdvancesViewModel(client: client)

        await model.load()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.response.advances.map(\.id) == [Self.advanceID])
        // The row renders straight off the envelope — no `transaction(id:)`.
        #expect(loaded.response.advances.first?.resolvedDescription == "TEST MERCHANT 01")
        #expect(await client.transactionFetchCount == 0)
        #expect(loaded.response.summary.totals.first?.outstanding == 4000)
        #expect(loaded.hasUnattributedReimbursements == false)
    }

    @Test func advancesForPersonKeyNarrowsToThatPersonAndCurrency() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([
            Self.makeAdvance(id: UUID(), transactionID: UUID(), participantName: "Marco", participantKey: "marco"),
            Self.makeAdvance(id: UUID(), transactionID: UUID(), participantName: "Giulia", participantKey: "giulia"),
        ])
        await client.setAdvancesSummary(Self.summary())
        let model = AdvancesViewModel(client: client)
        await model.load()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.advances(forPersonKey: "marco", currency: "EUR").count == 1)
        #expect(loaded.advances(forPersonKey: "giulia", currency: "EUR").count == 1)
        #expect(loaded.advances(forPersonKey: "marco", currency: "USD").isEmpty)
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

}
