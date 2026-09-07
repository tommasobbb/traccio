import Foundation
import Observation
import TraccioCore

/// Drives `AdvancesView`: the caller's advances, the cross-advance summary
/// (who owes what, how much in total), and the lifecycle-status filter.
///
/// Orchestration only, no derivation (`client/CLAUDE.md`): every figure —
/// per-advance `outstanding`, per-person roll-ups, per-currency totals — is
/// computed server-side (`domain/advances.py`, ADR 0026). This view model
/// calls `GET /advances`, resolves each advance's transaction and account so
/// a row can say *what* the advance was for, and publishes the result.
/// Nothing here logs an advance: participant names are user-typed
/// (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class AdvancesViewModel {
    /// Everything a loaded screen renders.
    struct Loaded {
        /// The `GET /advances` envelope: rows (filtered by `statusFilter`)
        /// plus the summary (always over every advance).
        var response: AdvancesResponse
        /// Advance's `transactionID` → its transaction, best-effort. A row
        /// whose transaction did not resolve still shows, just without a
        /// description/date.
        var transactionsByID: [UUID: TransactionResponse]
        /// Account id → account, for the detail screen's header.
        var accountsByID: [UUID: AccountResponse]
        /// `true` when some currency's per-person outstanding sum is below
        /// its per-currency total — i.e. reimbursements exist that are not
        /// attributed to any participant (ADR 0026). Precomputed here so the
        /// view stays a pure renderer.
        var hasUnattributedReimbursements: Bool
    }

    /// What the view should show right now.
    enum State {
        case idle
        case loading
        case loaded(Loaded)
        case failed
    }

    /// Current load state, observed by the view.
    private(set) var state: State = .idle
    /// The lifecycle filter applied to the *rows* (never the summary).
    /// `nil` means "all".
    private(set) var statusFilter: AdvanceStatus?

    /// Client used to reach the backend.
    private let client: any APIClientProtocol

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend; also handed to
    ///     `TransactionDetailView` so both screens share one client.
    init(client: any APIClientProtocol = APIClient.current) {
        self.client = client
    }

    /// Fetch the advances, their transactions/accounts, and publish the
    /// outcome. Keeps the current screen visible while refetching (e.g.
    /// after a filter change) rather than flashing a spinner.
    func load() async {
        switch state {
        case .idle, .failed:
            state = .loading
        case .loading, .loaded:
            break
        }

        let client = self.client
        let filter = statusFilter
        do {
            let response = try await client.advances(status: filter)
            async let accountsResult = client.accounts()

            let transactionsByID = await withTaskGroup(of: TransactionResponse?.self) { group in
                for advance in response.advances {
                    let id = advance.transactionID
                    group.addTask { try? await client.transaction(id: id) }
                }
                var resolved: [UUID: TransactionResponse] = [:]
                for await transaction in group {
                    if let transaction { resolved[transaction.id] = transaction }
                }
                return resolved
            }

            let accounts = (try? await accountsResult) ?? []
            state = .loaded(
                Loaded(
                    response: response,
                    transactionsByID: transactionsByID,
                    accountsByID: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) }),
                    hasUnattributedReimbursements: Self.hasUnattributedReimbursements(response.summary)
                )
            )
        } catch {
            state = .failed
        }
    }

    /// Change the lifecycle filter and reload. A no-op if unchanged.
    ///
    /// Parameters
    /// ----------
    /// newValue:
    ///     The status to show, or `nil` for all.
    func setStatusFilter(_ newValue: AdvanceStatus?) async {
        guard newValue != statusFilter else { return }
        statusFilter = newValue
        await load()
    }

    /// Whether any currency's per-person outstanding sum falls short of its
    /// per-currency total — the sign of reimbursements attributed to no
    /// participant (ADR 0026). Pure; total is server-authoritative, this
    /// only compares the two numbers to decide whether to explain the gap.
    private static func hasUnattributedReimbursements(_ summary: AdvancesSummaryResponse) -> Bool {
        let personOutstandingByCurrency = Dictionary(
            grouping: summary.byPerson, by: \.currency
        ).mapValues { rows in rows.reduce(0) { $0 + $1.outstanding } }

        return summary.totals.contains { total in
            (personOutstandingByCurrency[total.currency] ?? 0) < total.outstanding
        }
    }
}
