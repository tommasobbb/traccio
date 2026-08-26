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
    /// The period currently shown — a month, quarter, or year. Changing it
    /// (`goToPrevious()`/`goToNext()`/`changeUnit(_:)`) and reloading is how
    /// the period picker in `DashboardView` works.
    private(set) var period: CalendarPeriod
    /// The donut/breakdown-list selection — reset to `.none` on every
    /// `load()`, since a selected id from a previous period's category set
    /// carries no meaning in a new one.
    private(set) var selectedCategoryID: DonutSelection = .none
    /// Root category ids currently expanded in the breakdown list — reset on
    /// every `load()`, same reasoning as `selectedCategoryID`.
    private(set) var expandedRootIDs: Set<UUID> = []
    /// The trend chart's scrubbed/tapped bucket, or `nil` when nothing is
    /// selected — reset on every `load()`, since a bucket index from a
    /// previous period's (possibly differently-sized) series carries no
    /// meaning in a new one.
    private(set) var selectedBucketIndex: Int?

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
    ///     The period to load initially. Defaults to the current month.
    init(client: any APIClientProtocol = APIClient.current, period: CalendarPeriod = .current()) {
        self.client = client
        self.period = period
    }

    /// Fetch the summary for `period` and publish the outcome.
    ///
    /// Requests a comparison against `period.previous()` unconditionally —
    /// `ComparisonCard` always has something to show — and sends
    /// `period.granularity` and the device's own time zone, so `by_bucket`
    /// is bucketed the way the trend chart actually needs (day/week/month
    /// per unit) and in the zone the user actually reads dates in, not UTC.
    ///
    /// A failure is surfaced as `.failed` without carrying the error into the
    /// UI — error details may reference the response and must not be shown
    /// or logged. Also clears `selectedCategoryID`/`expandedRootIDs`/
    /// `selectedBucketIndex`, since any can reload with different data.
    func load() async {
        state = .loading
        selectedCategoryID = .none
        expandedRootIDs = []
        selectedBucketIndex = nil
        do {
            let compare = period.previous()
            let summary = try await client.dashboardSummary(
                start: period.start, end: period.end, granularity: period.granularity,
                tz: TimeZone.current.identifier, compareStart: compare.start, compareEnd: compare.end
            )
            state = .loaded(summary)
        } catch {
            state = .failed
        }
    }

    /// Step to the previous period (same unit) and reload.
    func goToPrevious() async {
        period = period.previous()
        await load()
    }

    /// Step to the next period (same unit) and reload.
    func goToNext() async {
        period = period.next()
        await load()
    }

    /// Switch the period picker's unit (Mese/Trimestre/Anno) and reload.
    ///
    /// Jumps to the *current* period of the new unit — e.g. switching from a
    /// month in March to "Trimestre" shows the quarter containing today, not
    /// an equivalent-length window around March — rather than trying to
    /// preserve some notion of "the same point in time" across units that
    /// don't align. A no-op when `unit` is already the active one.
    ///
    /// Parameters
    /// ----------
    /// unit:
    ///     The unit to switch to.
    func changeUnit(_ unit: CalendarPeriod.Unit) async {
        guard unit != period.unit else { return }
        period = .current(unit: unit)
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

    /// Select or deselect a bar on the trend chart.
    ///
    /// Unlike `selectCategory(_:)`, this never toggles — a scrub gesture
    /// reports the bucket currently under the finger on every move, and a
    /// released/cancelled gesture reports `nil`; there is no "already
    /// selected, so turn it off" case to collapse.
    ///
    /// Parameters
    /// ----------
    /// index:
    ///     The bucket index to select, or `nil` to clear the selection.
    func selectBucket(_ index: Int?) {
        selectedBucketIndex = index
    }

    /// The filter a drill-through to Movimenti should apply for a tapped
    /// trend-chart bucket.
    ///
    /// Parameters
    /// ----------
    /// start:
    ///     The bucket's inclusive start, as returned in `by_bucket`.
    /// end:
    ///     The bucket's exclusive end.
    ///
    /// Returns
    /// -------
    /// A filter scoped to `[start, end)`, or `nil` if either calendar date
    /// cannot be reconstructed into an instant (not expected in practice —
    /// the backend never sends an invalid date, but `CalendarDate.date(calendar:)`
    /// is honestly optional).
    func drillThroughFilter(bucketStart: CalendarDate, bucketEnd: CalendarDate) -> TransactionFilter? {
        guard let start = bucketStart.date(), let end = bucketEnd.date() else { return nil }
        return TransactionFilter(start: start, end: end)
    }
}
