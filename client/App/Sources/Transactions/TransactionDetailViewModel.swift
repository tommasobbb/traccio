import Foundation
import Observation
import TraccioCore

/// Drives `TransactionDetailView`: confirms or clears a transaction's
/// category, and holds the category list the picker renders.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`client/CLAUDE.md`). After a successful write it re-fetches the single
/// transaction via `transaction(id:)` rather than mutating
/// `effectiveCategoryID` locally, so the backend stays the only place that
/// resolves confirmed-vs-suggested (`domain/categories.py::effective_category`)
/// — see `docs/architecture.md`. Nothing here logs or prints a transaction:
/// it carries an amount and a raw bank description, both sensitive
/// (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class TransactionDetailViewModel {
    /// Why a category action failed, for the view to surface. Carries only a
    /// status-derived reason, never the response body — same shape as
    /// `AccountsViewModel.ActionFailure`.
    enum ActionFailure: Equatable {
        case generic
    }

    /// The transaction shown, refreshed in place after a successful
    /// confirm/clear.
    private(set) var transaction: TransactionResponse
    /// The caller's categories, for the picker. Seeded from
    /// `TransactionsViewModel.categories` (already fetched for the list) to
    /// avoid a flash of empty; `loadCategoriesIfNeeded()` fetches on its own
    /// when that seed is empty, so the screen is usable on its own too.
    private(set) var categories: [CategoryResponse]
    /// Set while a confirm/clear/seed-defaults call is in flight, to disable
    /// the picker and show a spinner rather than let a second tap race it.
    private(set) var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?

    /// Client used to reach the backend.
    private let client: any APIClientProtocol
    /// Invoked with the refreshed transaction after a successful confirm or
    /// clear, so the caller (`TransactionsViewModel.replace(_:)`) can update
    /// the Movimenti row in place without a full reload.
    private let onUpdate: (TransactionResponse) -> Void

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// transaction:
    ///     The transaction to show and act on.
    /// categories:
    ///     Categories already fetched by the caller, or empty to fetch fresh
    ///     via `loadCategoriesIfNeeded()`.
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onUpdate:
    ///     Called with the refreshed transaction after a successful write.
    ///     Defaults to a no-op for previews and callers that don't need it.
    init(
        transaction: TransactionResponse,
        categories: [CategoryResponse] = [],
        client: any APIClientProtocol = APIClient.devDefault,
        onUpdate: @escaping (TransactionResponse) -> Void = { _ in }
    ) {
        self.transaction = transaction
        self.categories = categories
        self.client = client
        self.onUpdate = onUpdate
    }

    /// Fetch categories if none were seeded at `init`.
    ///
    /// A no-op when `categories` is already non-empty — the common case,
    /// since `TransactionsViewModel` fetches them for every row's label
    /// before a detail screen is ever reached. Failure leaves `categories`
    /// empty; the view falls back to the "seed defaults" affordance.
    func loadCategoriesIfNeeded() async {
        guard categories.isEmpty else { return }
        if let fetched = try? await client.categories() {
            categories = fetched
        }
    }

    /// Seed the caller's default category set, for a fresh database with none
    /// yet — the picker would otherwise dead-end.
    func seedDefaultCategories() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            categories = try await client.seedDefaultCategories()
        } catch {
            actionFailure = .generic
        }
    }

    /// Confirm `categoryID` on the transaction, then re-fetch it.
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The category to confirm; must belong to the caller.
    func confirm(categoryID: UUID) async {
        await performUpdate { try await $0.confirmCategory(transactionID: $1, categoryID: categoryID) }
    }

    /// Clear the transaction's confirmed category, then re-fetch it.
    func clearCategory() async {
        await performUpdate { try await $0.clearCategory(transactionID: $1) }
    }

    /// Shared shape for `confirm(categoryID:)` and `clearCategory()`: guard
    /// against overlap, run the write, re-fetch the row on success, publish
    /// it, and notify `onUpdate` — or record `actionFailure` and leave
    /// `transaction` untouched on failure.
    ///
    /// Parameters
    /// ----------
    /// write:
    ///     The category write to perform, given the client and this
    ///     transaction's id.
    private func performUpdate(
        _ write: (any APIClientProtocol, UUID) async throws -> Void
    ) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await write(client, transaction.id)
            let refreshed = try await client.transaction(id: transaction.id)
            transaction = refreshed
            onUpdate(refreshed)
        } catch {
            actionFailure = .generic
        }
    }
}
