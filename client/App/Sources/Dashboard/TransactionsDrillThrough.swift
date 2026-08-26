import Observation
import TraccioCore

/// Cross-tab drill-through from Panoramica's category rows into a
/// pre-filtered Movimenti.
///
/// Movimenti lives in its own long-lived tab with its own `TransactionsView`
/// instance and `NavigationStack` — pushing a *second* `TransactionsView`
/// (which wraps its own `NavigationStack`) onto Panoramica's stack would nest
/// one navigation stack inside another, a real SwiftUI footgun (duplicated
/// nav bars, broken back-swipe). Switching tabs instead sidesteps that
/// entirely: `TraccioApp` gives the tab-level `TransactionsView` an `.id(_:)`
/// keyed to `generation`, so a new drill-through request forces SwiftUI to
/// throw away and rebuild that view (and its `@State` view model) fresh with
/// `filter` as its `initialFilter` — reusing the seam
/// `TransactionsViewModel.init(initialFilter:)` was already built for
/// (Task 3b's own doc comment: "a drill-through from another screen"). A
/// plain tab visit that isn't a drill-through never touches `generation`, so
/// the tab's list, scroll position, and pagination survive normally.
///
/// Owned by `TraccioApp` so both `DashboardView` (the requester) and the
/// `TabView` (the tag-switcher) observe the same instance — mirrors
/// `DataFreshness`'s cross-tab channel shape, for a one-shot navigation
/// intent rather than staleness.
@MainActor
@Observable
final class TransactionsDrillThrough {
    /// The filter the tab-level `TransactionsView` should load with —
    /// meaningful only alongside `generation`; read once at that view's
    /// construction, not observed continuously.
    private(set) var filter: TransactionFilter = .none
    /// Bumped by every `request(_:)`. `TraccioApp` keys the tab's
    /// `TransactionsView` to this via `.id(_:)` and watches it via
    /// `.onChange(of:)` to switch the visible tab.
    private(set) var generation = 0

    /// Request a drill-through: Movimenti should load with `filter`.
    ///
    /// Parameters
    /// ----------
    /// filter:
    ///     The filter to open Movimenti with.
    func request(_ filter: TransactionFilter) {
        self.filter = filter
        generation += 1
    }
}
