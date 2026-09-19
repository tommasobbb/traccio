import Foundation
import Observation
import TraccioCore

/// Drives `AdvancesView`: the caller's advances, the cross-advance summary
/// (who owes what, how much in total), and the lifecycle-status filter.
///
/// Orchestration only, no derivation (`docs/engineering.md`): every figure —
/// per-advance `outstanding`, per-person roll-ups, per-currency totals — is
/// computed server-side (`domain/advances.py`, ADR 0026). This view model
/// calls `GET /advances` and publishes the result; each row now carries its
/// own transaction description and date (`AdvanceResponse`), so there is no
/// per-advance fetch — a row navigates through `TransactionDetailLoader`,
/// which resolves the transaction only when opened. Nothing here logs an
/// advance: participant names are user-typed (`docs/engineering.md`).
@MainActor
@Observable
final class AdvancesViewModel {
    /// Everything a loaded screen renders.
    struct Loaded {
        /// The `GET /advances` envelope: rows (filtered by `statusFilter`)
        /// plus the summary (always over every in-window advance).
        var response: AdvancesResponse
        /// `true` when some currency's per-person outstanding sum is below
        /// its per-currency total — i.e. reimbursements exist that are not
        /// attributed to any participant (ADR 0026). Precomputed here so the
        /// view stays a pure renderer.
        var hasUnattributedReimbursements: Bool

        /// Every advance this person (`personKey` + `currency`) appears on,
        /// in list order — the drill-down's row source, filtered here so the
        /// view never re-folds a name (ADR 0026).
        func advances(forPersonKey personKey: String, currency: String) -> [AdvanceResponse] {
            response.advances.filter { advance in
                advance.currency == currency
                    && advance.participants.contains { $0.personKey == personKey }
            }
        }
    }

    /// Current load state, observed by the view.
    private(set) var state: LoadState<Loaded> = .idle
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

    /// Fetch the advances and publish the outcome. Keeps the current screen
    /// visible while refetching (e.g. after a filter change) rather than
    /// flashing a spinner.
    func load() async {
        state.beginLoading()

        let filter = statusFilter
        do {
            let response = try await client.advances(status: filter)
            state = .loaded(
                Loaded(
                    response: response,
                    hasUnattributedReimbursements: TraccioCore.hasUnattributedReimbursements(
                        response.summary
                    )
                )
            )
        } catch {
            // A cancelled request is not a failure — see
            // `TransactionsViewModel.loadPage()`'s identical guard.
            guard !error.isCancellationError else { return }
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
}
