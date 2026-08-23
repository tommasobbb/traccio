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
    /// This transaction's confirmed transfer, if `role == .transfer` and the
    /// lookup resolved. Cleared to `nil` after a successful
    /// `unlinkTransfer()`, since the row is `personal` again at that point.
    private(set) var transfer: TransferResponse?
    /// The counterpart leg's full transaction, for `TransferSection`'s
    /// display line. `TransfersByTransactionID` (`TransactionsViewModel`)
    /// only carries the `TransferResponse`, not the other leg's
    /// `TransactionResponse`, so `loadTransferIfNeeded()` fetches it here.
    private(set) var counterpartTransaction: TransactionResponse?
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
    /// transfer:
    ///     This transaction's confirmed transfer, if `role == .transfer` and
    ///     the caller's lookup resolved it. `nil` for every other role.
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onUpdate:
    ///     Called with the refreshed transaction after a successful write.
    ///     Defaults to a no-op for previews and callers that don't need it.
    init(
        transaction: TransactionResponse,
        categories: [CategoryResponse] = [],
        transfer: TransferResponse? = nil,
        client: any APIClientProtocol = APIClient.devDefault,
        onUpdate: @escaping (TransactionResponse) -> Void = { _ in }
    ) {
        self.transaction = transaction
        self.categories = categories
        self.transfer = transfer
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

    /// Fetch the counterpart leg's transaction, if this row has a `transfer`
    /// and it has not resolved yet.
    ///
    /// A no-op when there is no transfer or `counterpartTransaction` is
    /// already set. Failure leaves `counterpartTransaction` `nil`;
    /// `TransferSection` degrades to showing the unlink action without the
    /// counterpart line.
    func loadTransferIfNeeded() async {
        guard let transfer, counterpartTransaction == nil else { return }
        let counterpartID =
            transfer.outgoingTransactionID == transaction.id
            ? transfer.incomingTransactionID : transfer.outgoingTransactionID
        counterpartTransaction = try? await client.transaction(id: counterpartID)
    }

    /// Unlink this transaction's transfer, reverting both legs to
    /// `personal`.
    ///
    /// Unlike `confirm(categoryID:)`/`clearCategory()`, this touches *two*
    /// rows: after `DELETE /transfers/{id}` succeeds, both legs are
    /// re-fetched and each handed to `onUpdate` in turn (already matching by
    /// id, so no signature change needed) so `TransactionsViewModel.replace`
    /// updates both. `transfer`/`counterpartTransaction` are cleared to `nil`
    /// so `TransferSection` disappears from this screen without a full
    /// reload. Does not reuse `performUpdate` — that helper re-fetches only
    /// `transaction.id`, one row short of what an unlink needs.
    func unlinkTransfer() async {
        guard let transfer, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        let counterpartID =
            transfer.outgoingTransactionID == transaction.id
            ? transfer.incomingTransactionID : transfer.outgoingTransactionID

        do {
            try await client.deleteTransfer(id: transfer.id)
            async let own = client.transaction(id: transaction.id)
            async let counterpart = client.transaction(id: counterpartID)
            let (refreshedOwn, refreshedCounterpart) = try await (own, counterpart)
            transaction = refreshedOwn
            self.transfer = nil
            self.counterpartTransaction = nil
            onUpdate(refreshedOwn)
            onUpdate(refreshedCounterpart)
        } catch {
            actionFailure = .generic
        }
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
