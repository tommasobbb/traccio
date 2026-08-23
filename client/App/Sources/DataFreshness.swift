import Observation

/// A shared invalidation signal for screens whose data can go stale from a
/// write made on a different tab.
///
/// Carries no data of its own — only a token that increments whenever
/// something changed elsewhere. `DashboardView`/`TransactionsView` key their
/// `.task(id:)` to `token`, so a bump triggers a full re-fetch from the
/// backend, never a local recomputation: the same invalidate-and-refetch
/// discipline every write in this app already follows (see
/// `TransactionDetailViewModel`'s doc comment), scaled from one row to every
/// screen that reads it.
///
/// Injected once from `TraccioApp` via `.environment(_:)`. Today only
/// `CategorizationViewModel` calls `markStale()` (after `applyRules()` or
/// `deleteCategory(id:)`, both of which can change a transaction's
/// `effectiveCategoryID`); confirming a transfer, creating an advance, and
/// recording a reimbursement all have the same cross-tab staleness and are
/// not wired here yet — see `tasks/backlog.md`.
@MainActor
@Observable
final class DataFreshness {
    private(set) var token = 0

    /// Bump the token, so every `.task(id: freshness.token)` observer
    /// re-fetches.
    func markStale() {
        token += 1
    }
}
