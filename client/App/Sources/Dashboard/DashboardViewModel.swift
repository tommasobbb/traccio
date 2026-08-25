import Foundation
import Observation
import TraccioCore

/// Drives `DashboardView`: loads the period summary from the backend and
/// exposes the current load state and period for the view to render.
///
/// All it does is call `APIClient` and hold the result — no derivation, no
/// arithmetic (that lives in the backend, per `client/CLAUDE.md`). Nothing
/// here logs or prints the summary: it carries amounts, which are sensitive
/// (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class DashboardViewModel {
    /// What the view should show right now.
    enum State {
        case idle
        case loading
        case loaded(DashboardSummaryResponse)
        case failed
    }

    /// Current load state, observed by the view.
    private(set) var state: State = .idle
    /// The month currently shown. Changing it and calling `load()` again is
    /// how the period picker in `DashboardView` works.
    private(set) var period: MonthPeriod

    /// Client used to reach the backend. `any APIClientProtocol` rather than
    /// the concrete `APIClient` (`.claude/rules/swift.md`: "a view model
    /// depends on a protocol and tests inject a fake") — a test can supply a
    /// fake without a network stub.
    private let client: any APIClientProtocol

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to fetch the summary through. Defaults to a client
    ///     pointed at the local dev backend.
    /// period:
    ///     The month to load initially. Defaults to the current month.
    init(client: any APIClientProtocol = APIClient.current, period: MonthPeriod = .current()) {
        self.client = client
        self.period = period
    }

    /// Fetch the summary for `period` and publish the outcome.
    ///
    /// A failure is surfaced as `.failed` without carrying the error into the
    /// UI — error details may reference the response and must not be shown
    /// or logged.
    func load() async {
        state = .loading
        do {
            let summary = try await client.dashboardSummary(start: period.start, end: period.end)
            state = .loaded(summary)
        } catch {
            state = .failed
        }
    }

    /// Step to the previous month and reload.
    func goToPreviousMonth() async {
        period = period.previous()
        await load()
    }

    /// Step to the next month and reload.
    func goToNextMonth() async {
        period = period.next()
        await load()
    }
}
