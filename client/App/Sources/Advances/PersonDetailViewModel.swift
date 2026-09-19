import Foundation
import Observation
import TraccioCore

/// Drives `PersonDetailView`: one person's receivable, rolled up across every
/// advance they appear on, plus that list of advances.
///
/// Orchestration only (`docs/engineering.md`). The person row (`expected`,
/// `reimbursed`, `outstanding`) is `PersonSummaryResponse`, computed
/// server-side; the advances are `GET /advances`'s rows filtered to this
/// person by the server-issued `personKey` (never a name re-folded here,
/// ADR 0026). A write on a pushed `TransactionDetailLoader` — a reimbursement,
/// a write-off — changes these numbers, so the screen refetches on return.
@MainActor
@Observable
final class PersonDetailViewModel {
    struct Loaded {
        /// This person's roll-up row. Falls back to the last known row when a
        /// refetch no longer lists the person (every advance settled) so the
        /// screen shows zeros rather than an error.
        var person: PersonSummaryResponse
        /// The advances this person appears on, in list order.
        var advances: [AdvanceResponse]
    }

    enum State {
        case loaded(Loaded)
        case failed
    }

    private(set) var state: State

    /// Identity of the person this screen is about — matched on the server's
    /// own grouping key plus currency (ADR 0026).
    private let personKey: String
    private let currency: String
    private let client: any APIClientProtocol

    /// Create the view model with the data the list already had, so the first
    /// paint has no loading flash; `refresh()` then reconciles with the server.
    init(
        person: PersonSummaryResponse,
        advances: [AdvanceResponse],
        client: any APIClientProtocol = APIClient.current
    ) {
        self.personKey = person.personKey
        self.currency = person.currency
        self.client = client
        self.state = .loaded(Loaded(person: person, advances: advances))
    }

    /// Refetch `GET /advances` and re-narrow to this person. Keeps the current
    /// content visible on failure — the injected snapshot is still useful.
    func refresh() async {
        do {
            let response = try await client.advances(status: nil)
            let advances = response.advances.filter { advance in
                advance.currency == currency
                    && advance.participants.contains { $0.personKey == personKey }
            }
            let person =
                response.summary.byPerson.first {
                    $0.personKey == personKey && $0.currency == currency
                } ?? settledFallback
            state = .loaded(Loaded(person: person, advances: advances))
        } catch {
            if case .loaded = state { return }
            state = .failed
        }
    }

    /// A zeroed row for a person the server no longer lists because every
    /// advance of theirs settled — keeps the name and currency.
    private var settledFallback: PersonSummaryResponse {
        let name: String
        if case .loaded(let loaded) = state { name = loaded.person.name } else { name = personKey }
        return PersonSummaryResponse(
            name: name,
            personKey: personKey,
            currency: currency,
            expected: 0,
            reimbursed: 0,
            outstanding: 0,
            advanceCount: 0
        )
    }
}
