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

    /// Which donut segment (and matching breakdown row) is currently
    /// highlighted. Not a plain `UUID??` — that would let "nothing selected"
    /// and "the no-category segment selected" collapse into ambiguous
    /// optional-of-optional nesting; this enum makes both states explicit
    /// (`.claude/rules/swift.md`: "make illegal states unrepresentable").
    enum DonutSelection: Equatable {
        case none
        case category(UUID?)
    }

    /// Current load state, observed by the view.
    private(set) var state: State = .idle
    /// The month currently shown. Changing it and calling `load()` again is
    /// how the period picker in `DashboardView` works.
    private(set) var period: MonthPeriod
    /// The donut/breakdown-list selection — reset to `.none` on every
    /// `load()`, since a selected id from a previous period's category set
    /// carries no meaning in a new one.
    private(set) var selectedCategoryID: DonutSelection = .none
    /// Root category ids currently expanded in the breakdown list — reset on
    /// every `load()`, same reasoning as `selectedCategoryID`.
    private(set) var expandedRootIDs: Set<UUID> = []

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
    /// or logged. Also clears `selectedCategoryID`/`expandedRootIDs`, since
    /// either can reload with a different category set.
    func load() async {
        state = .loading
        selectedCategoryID = .none
        expandedRootIDs = []
        do {
            let summary = try await client.dashboardSummary(
                start: period.start, end: period.end, granularity: .day, tz: nil,
                compareStart: nil, compareEnd: nil
            )
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

    /// Select or deselect a category on the donut/breakdown list.
    ///
    /// Tapping the already-selected category (donut segment or, one day, a
    /// row) toggles back to `.none` rather than staying stuck selected.
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The category to select — `nil` for the "no category" segment, a
    ///     real id otherwise.
    func selectCategory(_ categoryID: UUID?) {
        let target = DonutSelection.category(categoryID)
        selectedCategoryID = selectedCategoryID == target ? .none : target
    }

    /// Expand or collapse a root's children in the breakdown list.
    ///
    /// Parameters
    /// ----------
    /// rootID:
    ///     The root category to toggle.
    func toggleExpanded(_ rootID: UUID) {
        if expandedRootIDs.contains(rootID) {
            expandedRootIDs.remove(rootID)
        } else {
            expandedRootIDs.insert(rootID)
        }
    }

    /// The filter a drill-through to Movimenti should apply for `categoryID`,
    /// scoped to the period currently shown.
    ///
    /// `GET /transactions?category_id=<id>` already rolls a root id up to
    /// include its children (ADR 0018), so this is exact for a root or child
    /// row; there is no narrower filter for a root's own direct-spending
    /// remainder row, which is why `CategoryBreakdownList` does not offer a
    /// drill-through for one (see its own doc comment).
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The row's category, or `nil` for the "no category" bucket.
    ///
    /// Returns
    /// -------
    /// A filter scoped to `categoryID` (or `.uncategorized` when `nil`) and
    /// this view model's current `period`.
    func drillThroughFilter(categoryID: UUID?) -> TransactionFilter {
        TransactionFilter(
            category: categoryID.map(TransactionFilter.CategoryFilter.some) ?? .uncategorized,
            start: period.start,
            end: period.end
        )
    }
}
