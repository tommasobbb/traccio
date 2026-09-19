import Foundation
import Observation
import TraccioCore

/// Drives `DashboardView`: loads the period summary from the backend and
/// exposes the current load state and period for the view to render.
///
/// All it does is call `APIClient` and hold the result — no derivation, no
/// arithmetic (that lives in the backend, per `docs/engineering.md`). Nothing
/// here logs or prints the summary: it carries amounts, which are sensitive
/// (`docs/engineering.md`).
@MainActor
@Observable
final class DashboardViewModel {
    /// Which donut segment (and matching breakdown row) is currently
    /// highlighted. Not a plain `UUID??` — that would let "nothing selected"
    /// and "the no-category segment selected" collapse into ambiguous
    /// optional-of-optional nesting; this enum makes both states explicit
    /// (`docs/engineering.md`: "make illegal states unrepresentable").
    enum DonutSelection: Equatable {
        case none
        case category(UUID?)
    }

    /// Current load state, observed by the view.
    private(set) var state: LoadState<DashboardSummaryResponse> = .idle
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
    /// The user's tracking start date (ADR 0024), refreshed on every `load()`
    /// (it can change from Impostazioni while the app runs). The backend
    /// floors every total at it regardless; this is only so the period picker
    /// can stop the user paging to a period entirely before it, which would
    /// just show an empty screen. `nil` = no explicit floor.
    private(set) var trackingStart: CalendarDate?
    /// The earliest movement date across all accounts, from
    /// `GET /settings/tracking-start/suggestion` — fetched once, since it only
    /// moves when a new account is connected (not a `DataFreshness.dashboard`
    /// event). The backward floor when no explicit `trackingStart` is set:
    /// there is simply nothing to show before it. `nil` until loaded, or if
    /// no account has a dated movement.
    private(set) var earliestMovement: Date?
    private var didLoadEarliestMovement = false

    /// Whether stepping to the previous period would still overlap the
    /// backward floor — the explicit tracking start if set, otherwise the
    /// earliest movement date. `true` when neither is known.
    var canGoToPrevious: Bool {
        guard let floor = trackingStart?.date() ?? earliestMovement else { return true }
        return period.previous().end > floor
    }

    /// Whether stepping forward lands on a period that has already begun.
    /// `false` stops the user paging into empty future months — there is
    /// nothing there yet, and the tracking-start feature exists precisely to
    /// bound the window that is worth counting.
    var canGoToNext: Bool {
        !period.next().isEntirelyAfter(now())
    }

    /// Client used to reach the backend. `any APIClientProtocol` rather than
    /// the concrete `APIClient` (`docs/engineering.md`: "a view model
    /// depends on a protocol and tests inject a fake") — a test can supply a
    /// fake without a network stub.
    private let client: any APIClientProtocol
    /// Wall clock, injectable so a test can pin "now" rather than depend on
    /// the real date when checking `canGoToNext`.
    private let now: () -> Date

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to fetch the summary through. Defaults to a client
    ///     pointed at the local dev backend.
    /// period:
    ///     The period to load initially. Defaults to the current month.
    /// now:
    ///     The wall clock. Defaults to `Date.init`; a test injects a fixed
    ///     date to exercise `canGoToNext`.
    init(
        client: any APIClientProtocol = APIClient.current,
        period: CalendarPeriod = .current(),
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.period = period
        self.now = now
    }

    /// Reload the summary *and* refresh the period-picker bounds (the
    /// tracking start and the earliest-movement floor). For the first appear
    /// and a `DataFreshness.dashboard` bump; period navigation calls
    /// `reloadSummary()` alone, since the bounds do not depend on which
    /// period is shown.
    ///
    /// The bounds fetches are best-effort — a failure just leaves the picker
    /// unconstrained, never `.failed`.
    func load() async {
        await reloadSummary()
        // The tracking start can change from Impostazioni between loads.
        // Best-effort: a failure just leaves the picker unconstrained.
        if let settings = try? await client.settings() {
            trackingStart = settings.trackingStartDate
        }
        // The earliest-movement floor only moves when an account is
        // connected — not a .dashboard event — so fetch it once.
        if !didLoadEarliestMovement {
            didLoadEarliestMovement = true
            if let suggestion = try? await client.trackingStartSuggestion() {
                earliestMovement = suggestion.accounts.compactMap { $0.earliest?.date() }.min()
            }
        }
    }

    /// Fetch the summary for `period` and publish the outcome. Clears
    /// `selectedCategoryID`/`expandedRootIDs`/`selectedBucketIndex`, since any
    /// can reload with different data.
    ///
    /// Requests a comparison against `period.previous()` unconditionally —
    /// the hero footnote's comparison chunk always has something to show —
    /// and sends `period.granularity` and the device's own time zone.
    func reloadSummary() async {
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

    /// Step to the previous period (same unit) and reload the summary.
    ///
    /// A no-op when the previous period lies entirely before the backward
    /// floor (`canGoToPrevious`) — there is nothing there to show.
    func goToPrevious() async {
        guard canGoToPrevious else { return }
        period = period.previous()
        await reloadSummary()
    }

    /// Step to the next period (same unit) and reload the summary.
    ///
    /// A no-op when the next period has not begun yet (`canGoToNext`).
    func goToNext() async {
        guard canGoToNext else { return }
        period = period.next()
        await reloadSummary()
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
        await reloadSummary()
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
