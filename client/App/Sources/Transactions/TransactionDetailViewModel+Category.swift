import Foundation
import TraccioCore

/// Resolving this transaction's category name for `TransactionHeaderCard`.
///
/// The actual category writes (confirm/clear/seed/create-rule) moved to
/// `TransactionsViewModel+Category.swift` once categorizing became a row-level
/// action reached from a Movimenti row's leading tile rather than this pushed
/// screen (`docs/decisions/0036-movimenti-row-actions.md`). `categories`
/// itself stays here, read-only, purely so the header can show a name —
/// dropping it would leave the header blank for a confirmed category on a
/// transaction reached from the Anticipi tab, where `TransactionDetailLoader`
/// has no category list of its own to hand in.
extension TransactionDetailViewModel {
    /// Fetch categories if none were seeded at `init`.
    ///
    /// A no-op when `categories` is already non-empty — the common case,
    /// since `TransactionsViewModel` fetches them for every row's label
    /// before a detail screen is ever reached. Failure leaves `categories`
    /// empty; the header simply shows no category badge.
    func loadCategoriesIfNeeded() async {
        guard categories.isEmpty else { return }
        if let fetched = try? await client.categories() {
            categories = fetched
        }
    }
}
