import Observation

/// A shared invalidation signal for screens whose data can go stale from a
/// write made on a different tab.
///
/// Carries no data of its own — only per-`Scope` tokens that increment
/// whenever something changed elsewhere. Each screen keys its own
/// `.task(id:)` to `token(for:)` for the scope(s) it reads, so a bump
/// triggers a full re-fetch from the backend for that screen only, never a
/// local recomputation: the same invalidate-and-refetch discipline every
/// write in this app already follows (see `TransactionDetailViewModel`'s doc
/// comment), scaled from one row to every screen that reads it.
///
/// Scoped rather than one flat token so that, e.g., confirming a category on
/// `TransactionDetailView` — which changes `.dashboard` totals but not the
/// Movimenti list's own contents (that row is already updated in place via
/// `onUpdate`) — does not also reset Movimenti's scroll position and
/// pagination by re-triggering its `.task(id:)` for no reason.
///
/// Injected once from `TraccioApp` via `.environment(_:)`.
@MainActor
@Observable
final class DataFreshness {
    /// A screen whose data can be invalidated independently of the others.
    enum Scope: Hashable {
        /// `DashboardView` — spending/income/net and the category breakdown,
        /// all derived from `effective_amount` and `effective_category`
        /// server-side. Bumped by any write that can change either: a
        /// category confirm/clear, a transfer confirm/reject/unlink, or an
        /// advance/reimbursement create/delete/write-off/reopen.
        case dashboard
        /// `TransactionsView`'s own list contents — bumped only by a write
        /// that changes *which* transactions should appear or how many
        /// (e.g. applying categorization rules can change suggested
        /// categories across the whole page). A single row's own fields
        /// (role, category) are kept in sync via `onUpdate` without a full
        /// reload, so most writes on `TransactionDetailView` do not bump
        /// this scope.
        case transactions
    }

    private var tokens: [Scope: Int] = [:]

    /// The current token for `scope`, to key a `.task(id:)` to.
    func token(for scope: Scope) -> Int {
        tokens[scope, default: 0]
    }

    /// Bump every scope in `scopes`, so each one's `.task(id:)` observers
    /// re-fetch.
    func markStale(_ scopes: Set<Scope>) {
        for scope in scopes {
            tokens[scope, default: 0] += 1
        }
    }
}
