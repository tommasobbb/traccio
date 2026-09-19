import Foundation
import Observation
import TraccioCore

/// Drives `TransactionDetailView`: the event, transfer, reimbursement, and
/// *existing*-advance actions that stay on this pushed screen. Categorizing,
/// marking as an advance, and editing/deleting a manual movement all moved to
/// `TransactionsViewModel` once they became row-level actions
/// (`docs/decisions/0036-movimenti-row-actions.md`) — this type keeps only a
/// read-only `categories` list, to resolve the header's category name.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`docs/engineering.md`). After a successful write it re-fetches the single
/// transaction via `transaction(id:)` rather than mutating derived fields
/// locally, so the backend stays the only place that resolves them
/// (`docs/architecture.md`). Nothing here logs or prints a transaction: it
/// carries an amount and a raw bank description, both sensitive
/// (`docs/engineering.md`).
///
/// The type is split by concern across `TransactionDetailViewModel+*.swift`
/// in this directory (transfer, advance, reimbursement, event, and the
/// single `loadCategoriesIfNeeded()` left in `+Category.swift`), the same
/// pattern `APIClient+*.swift` uses in `TraccioCore`. Splitting a class
/// across files means Swift's `private` (file-scoped) cannot protect these
/// members from the rest of the app target the way it protects `APIClient`'s
/// transport internals from other modules — so, exactly as `APIClient`'s
/// `baseURL`/`apiToken`/`session` are `internal` rather than `private` for
/// the same reason, the state below is `internal`. Treat it as this type's
/// private implementation: only its own extensions read or write it; every
/// other caller goes through the methods declared there.
@MainActor
@Observable
final class TransactionDetailViewModel {
    /// Why a category action failed, for the view to surface. Carries only a
    /// status-derived reason, never the response body — same shape as
    /// `AccountsViewModel.ActionFailure`.
    enum ActionFailure: Equatable {
        case generic
        /// `409` from `POST /events/{id}/transactions` — this transaction
        /// already belongs to a different event.
        case transactionInAnotherEvent
        /// `422` from the same endpoint — the event and this transaction
        /// don't share a currency.
        case mixedCurrency
    }

    /// This transaction's advance's recorded reimbursements, oldest first —
    /// distinct from a plain array so a load failure ("`.failed`") is never
    /// confused with "no reimbursements exist yet" (`.loaded([])`), which
    /// would be a lie whenever `advance.reimbursed > 0`.
    enum ReimbursementsState: Equatable {
        case loading
        case loaded([ReimbursementResponse])
        case failed
    }

    /// The transaction shown, refreshed in place after a successful
    /// confirm/clear.
    var transaction: TransactionResponse
    /// This transaction's advance, if it has one. Seeded at `init` from
    /// `TransactionsViewModel.advancesByTransactionID`; refreshed in place
    /// after `createAdvance(ownShare:participants:)` or
    /// `deleteAdvance()` succeeds — unlike `AdvanceSections`'s previous
    /// `let`, this can now change as a side effect of a user action on this
    /// screen, not just from what the caller passed in.
    var advance: AdvanceResponse?
    /// The caller's categories, read-only — resolves `categoryName` for
    /// `TransactionHeaderCard`'s badge (categorizing itself is a row-level
    /// action now, `docs/decisions/0036-movimenti-row-actions.md`). Seeded
    /// from `TransactionsViewModel.categories` (already fetched for the
    /// list) to avoid a flash of empty; `loadCategoriesIfNeeded()` fetches on
    /// its own when that seed is empty (the Anticipi entry path), so the
    /// screen is usable on its own too.
    var categories: [CategoryResponse]
    /// This transaction's confirmed transfer, if `role == .transfer` and the
    /// lookup resolved. Cleared to `nil` after a successful
    /// `unlinkTransfer()`, since the row is `personal` again at that point.
    var transfer: TransferResponse?
    /// The counterpart leg's full transaction, for `TransferSection`'s
    /// display line. `TransfersByTransactionID` (`TransactionsViewModel`)
    /// only carries the `TransferResponse`, not the other leg's
    /// `TransactionResponse`, so `loadTransferIfNeeded()` fetches it here.
    var counterpartTransaction: TransactionResponse?
    /// Transactions eligible to be linked as a reimbursement for this
    /// transaction's advance: `personal`, incoming, same currency.
    /// Best-effort, loaded on demand via
    /// `loadReimbursementCandidatesIfNeeded()` when
    /// `AddReimbursementSheet` opens — a failure leaves it empty, which the
    /// sheet degrades to offering a cash-only entry.
    var reimbursementCandidates: [TransactionResponse] = []
    /// Account id → account, fetched alongside the candidates so
    /// `AddReimbursementSheet` can name each candidate's destination account.
    /// Best-effort, same as the candidates: an empty map degrades every row
    /// to a generic "Conto" label.
    var reimbursementCandidateAccounts: [UUID: AccountResponse] = [:]
    /// This transaction's advance's recorded reimbursements, loaded by
    /// `loadReimbursements()` and kept in sync by
    /// `createReimbursement(...)`/`deleteReimbursement(_:)`. `.loading` until
    /// the first fetch resolves.
    var reimbursements: ReimbursementsState = .loading
    /// Set while a confirm/clear/seed-defaults call is in flight, to disable
    /// the picker and show a spinner rather than let a second tap race it.
    var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    var actionFailure: ActionFailure?
    /// Increments once per successful category confirm/clear, advance
    /// creation, or reimbursement creation — a trigger for
    /// `.sensoryFeedback(.success, trigger:)`, not a count anyone reads.
    /// `actionFailure` already covers the failure trigger; this is its
    /// success-side counterpart, needed because it must change on *every*
    /// success (including a second identical one in a row), which a `Bool`
    /// flipping to the same value again would not.
    var successTick = 0

    /// Client used to reach the backend. `internal`, not `private` — see the
    /// type's doc comment.
    let client: any APIClientProtocol
    /// Invoked with the refreshed transaction after a successful confirm or
    /// clear, so the caller (`TransactionsViewModel.replace(_:)`) can update
    /// the Movimenti row in place without a full reload.
    let onUpdate: (TransactionResponse) -> Void
    /// Invoked with this transaction's current advance (`nil` once it has
    /// none) after a successful create/delete, so the caller
    /// (`TransactionsViewModel.updateAdvance(_:for:)`) can keep
    /// `advancesByTransactionID` in sync — an advance is not part of
    /// `TransactionResponse`, so `onUpdate` alone cannot carry this.
    let onAdvanceChange: (AdvanceResponse?) -> Void
    /// Invoked after any successful write on this screen that can change
    /// `GET /dashboard/summary`'s totals — a category confirm/clear, an
    /// unlink, or an advance/reimbursement create/delete/write-off/reopen.
    /// The caller (`SettingsView`'s pattern via `TraccioApp`'s shared
    /// `DataFreshness`) bumps `.dashboard` so Panoramica re-fetches rather
    /// than showing a now-stale total — see `DataFreshness`'s doc comment.
    let onDashboardStale: () -> Void

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// transaction:
    ///     The transaction to show and act on.
    /// advance:
    ///     This transaction's advance, if it has one and the caller's lookup
    ///     resolved it. `nil` for every other role, or if the lookup failed.
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
    /// onAdvanceChange:
    ///     Called with the transaction's current advance after a successful
    ///     create/delete. Defaults to a no-op for previews and callers that
    ///     don't need it.
    /// onDashboardStale:
    ///     Called after any successful write that can change the dashboard's
    ///     totals. Defaults to a no-op for previews and callers that don't
    ///     need it.
    init(
        transaction: TransactionResponse,
        advance: AdvanceResponse? = nil,
        categories: [CategoryResponse] = [],
        transfer: TransferResponse? = nil,
        client: any APIClientProtocol = APIClient.current,
        onUpdate: @escaping (TransactionResponse) -> Void = { _ in },
        onAdvanceChange: @escaping (AdvanceResponse?) -> Void = { _ in },
        onDashboardStale: @escaping () -> Void = {}
    ) {
        self.transaction = transaction
        self.advance = advance
        self.categories = categories
        self.transfer = transfer
        self.client = client
        self.onUpdate = onUpdate
        self.onAdvanceChange = onAdvanceChange
        self.onDashboardStale = onDashboardStale
    }
}
