import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `PersonDetailViewModel` against `FakeAPIClient` — the seam, not
/// the implementation (`docs/engineering.md`). Synthetic fixtures
/// (`docs/engineering.md`): invented ids and names, round amounts.
@MainActor
struct PersonDetailViewModelTests {
    private static func person(
        key: String = "marco", outstanding: Int = 3000, count: Int = 2
    ) -> PersonSummaryResponse {
        PersonSummaryResponse(
            name: "Marco", personKey: key, currency: "EUR",
            expected: 5000, reimbursed: 5000 - outstanding, outstanding: outstanding,
            advanceCount: count
        )
    }

    private static func advance(
        key: String, currency: String = "EUR", status: AdvanceStatus = .open
    ) -> AdvanceResponse {
        AdvanceResponse(
            id: UUID(), transactionID: UUID(),
            description: "TEST MERCHANT 01", displayDescription: nil,
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            ownShare: 1000, receivable: 2500, reimbursed: 0, outstanding: 2500, excess: 0,
            currency: currency, status: status,
            participants: [
                ParticipantResponse(
                    id: UUID(), name: "Marco", personKey: key, expectedAmount: 2500,
                    reimbursed: 0, outstanding: 2500, excess: 0, status: .outstanding
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    private static func summary(_ people: [PersonSummaryResponse]) -> AdvancesSummaryResponse {
        AdvancesSummaryResponse(
            byPerson: people,
            totals: [
                ReceivableTotalResponse(
                    currency: "EUR", outstanding: 3000, expected: 3000, reimbursed: 0, openAdvances: 2
                )
            ]
        )
    }

    @Test func firstPaintUsesTheInjectedSnapshotWithNoFetch() async throws {
        let client = FakeAPIClient()
        let model = PersonDetailViewModel(
            person: Self.person(), advances: [Self.advance(key: "marco")], client: client
        )

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.person.name == "Marco")
        #expect(loaded.advances.count == 1)
    }

    @Test func refreshReNarrowsToThePersonKeyAndCurrency() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([
            Self.advance(key: "marco"),
            Self.advance(key: "giulia"),
            Self.advance(key: "marco", currency: "USD"),
        ])
        await client.setAdvancesSummary(Self.summary([Self.person()]))
        let model = PersonDetailViewModel(person: Self.person(), advances: [], client: client)

        await model.refresh()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.advances.count == 1)  // only "marco" in EUR
        #expect(loaded.person.outstanding == 3000)
    }

    @Test func refreshFallsBackToZeroWhenTheServerNoLongerListsThePerson() async throws {
        let client = FakeAPIClient()
        await client.setAdvances([Self.advance(key: "giulia")])
        await client.setAdvancesSummary(Self.summary([Self.person(key: "giulia")]))
        let model = PersonDetailViewModel(
            person: Self.person(), advances: [Self.advance(key: "marco")], client: client
        )

        await model.refresh()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.person.name == "Marco")  // name kept
        #expect(loaded.person.outstanding == 0)
        #expect(loaded.advances.isEmpty)
    }

    @Test func refreshFailureKeepsTheCurrentContent() async throws {
        let client = FakeAPIClient()
        await client.setAdvancesError(FakeAPIError())
        let model = PersonDetailViewModel(
            person: Self.person(), advances: [Self.advance(key: "marco")], client: client
        )

        await model.refresh()

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected .loaded to survive a failed refresh")
            return
        }
        #expect(loaded.advances.count == 1)
    }
}
