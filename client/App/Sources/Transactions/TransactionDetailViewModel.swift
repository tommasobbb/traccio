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
    private(set) var transaction: TransactionResponse
    /// This transaction's advance, if it has one. Seeded at `init` from
    /// `TransactionsViewModel.advancesByTransactionID`; refreshed in place
    /// after `createAdvance(ownShare:participants:)` or
    /// `deleteAdvance()` succeeds — unlike `AdvanceSections`'s previous
    /// `let`, this can now change as a side effect of a user action on this
    /// screen, not just from what the caller passed in.
    private(set) var advance: AdvanceResponse?
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
    /// Transactions eligible to be linked as a reimbursement for this
    /// transaction's advance: `personal`, incoming, same currency.
    /// Best-effort, loaded on demand via
    /// `loadReimbursementCandidatesIfNeeded()` when
    /// `AddReimbursementSheet` opens — a failure leaves it empty, which the
    /// sheet degrades to offering a cash-only entry.
    private(set) var reimbursementCandidates: [TransactionResponse] = []
    /// This transaction's advance's recorded reimbursements, loaded by
    /// `loadReimbursements()` and kept in sync by
    /// `createReimbursement(...)`/`deleteReimbursement(_:)`. `.loading` until
    /// the first fetch resolves.
    private(set) var reimbursements: ReimbursementsState = .loading
    /// Set while a confirm/clear/seed-defaults call is in flight, to disable
    /// the picker and show a spinner rather than let a second tap race it.
    private(set) var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?
    /// Increments once per successful category confirm/clear, advance
    /// creation, or reimbursement creation — a trigger for
    /// `.sensoryFeedback(.success, trigger:)`, not a count anyone reads.
    /// `actionFailure` already covers the failure trigger; this is its
    /// success-side counterpart, needed because it must change on *every*
    /// success (including a second identical one in a row), which a `Bool`
    /// flipping to the same value again would not.
    private(set) var successTick = 0

    /// Client used to reach the backend.
    private let client: any APIClientProtocol
    /// Invoked with the refreshed transaction after a successful confirm or
    /// clear, so the caller (`TransactionsViewModel.replace(_:)`) can update
    /// the Movimenti row in place without a full reload.
    private let onUpdate: (TransactionResponse) -> Void
    /// Invoked with this transaction's current advance (`nil` once it has
    /// none) after a successful create/delete, so the caller
    /// (`TransactionsViewModel.updateAdvance(_:for:)`) can keep
    /// `advancesByTransactionID` in sync — an advance is not part of
    /// `TransactionResponse`, so `onUpdate` alone cannot carry this.
    private let onAdvanceChange: (AdvanceResponse?) -> Void
    /// Invoked after any successful write on this screen that can change
    /// `GET /dashboard/summary`'s totals — a category confirm/clear, an
    /// unlink, or an advance/reimbursement create/delete/write-off/reopen.
    /// The caller (`SettingsView`'s pattern via `TraccioApp`'s shared
    /// `DataFreshness`) bumps `.dashboard` so Panoramica re-fetches rather
    /// than showing a now-stale total — see `DataFreshness`'s doc comment.
    private let onDashboardStale: () -> Void

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
            onDashboardStale()
        } catch {
            actionFailure = .generic
        }
    }

    /// Create an advance on this transaction — the explicit user action from
    /// `CreateAdvanceSheet`.
    ///
    /// On success, both the created advance and the refreshed transaction
    /// (its `role` is now `advance`, `effectiveAmount` now `ownShare`) are
    /// published, and both `onUpdate`/`onAdvanceChange` fire so the caller
    /// can update the Movimenti row and `advancesByTransactionID` alike.
    /// Unlike `performUpdate`, this also needs the created advance itself
    /// (not part of `TransactionResponse`), so it does not reuse that
    /// helper.
    ///
    /// Parameters
    /// ----------
    /// ownShare:
    ///     The user's declared share, a positive magnitude in the
    ///     transaction's currency. The backend validates the range; an
    ///     out-of-range value surfaces as `actionFailure`.
    /// participants:
    ///     People who owe the user back; may be empty.
    func createAdvance(ownShare: Int, participants: [ParticipantRequest]) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            let created = try await client.createAdvance(
                CreateAdvanceRequest(
                    transactionID: transaction.id, ownShare: ownShare, participants: participants
                )
            )
            let refreshed = try await client.transaction(id: transaction.id)
            transaction = refreshed
            advance = created
            onUpdate(refreshed)
            onAdvanceChange(created)
            onDashboardStale()
            successTick += 1
        } catch {
            actionFailure = .generic
        }
    }

    /// Delete this transaction's advance, reverting it to `personal`.
    ///
    /// A no-op without an advance. On success, both the refreshed transaction
    /// (`effectiveAmount` is the full amount again) and the now-`nil`
    /// advance are published and handed to `onUpdate`/`onAdvanceChange`.
    func deleteAdvance() async {
        guard let advance, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await client.deleteAdvance(id: advance.id)
            let refreshed = try await client.transaction(id: transaction.id)
            transaction = refreshed
            self.advance = nil
            onUpdate(refreshed)
            onAdvanceChange(nil)
            onDashboardStale()
        } catch {
            actionFailure = .generic
        }
    }

    /// Write off this transaction's advance — given up on, folded into
    /// spending instead of staying "to receive".
    ///
    /// A no-op without an advance. On success, the updated advance (`status
    /// == .writtenOff`) is published and handed to `onAdvanceChange`; the
    /// transaction itself is untouched (write-off does not change `role`).
    func writeOffAdvance() async {
        await performAdvanceUpdate { try await $0.writeOffAdvance(id: $1) }
    }

    /// Reopen a previously written-off advance — the inverse of
    /// `writeOffAdvance()`.
    func reopenAdvance() async {
        await performAdvanceUpdate { try await $0.reopenAdvance(id: $1) }
    }

    /// Fetch this transaction's reimbursement candidates, if not already
    /// loaded.
    ///
    /// A no-op when `reimbursementCandidates` is already non-empty. Failure
    /// leaves it empty; `AddReimbursementSheet` still works for a cash-only
    /// entry.
    func loadReimbursementCandidatesIfNeeded() async {
        guard reimbursementCandidates.isEmpty else { return }
        guard let fetched = try? await client.transactions(filter: .none, limit: 100, offset: 0)
        else { return }
        reimbursementCandidates = fetched.filter {
            $0.role == .personal && $0.amount > 0 && $0.currency == transaction.currency
        }
    }

    /// Fetch this transaction's advance's recorded reimbursements.
    ///
    /// A no-op without an advance. Unlike
    /// `loadReimbursementCandidatesIfNeeded()`, this always re-runs when
    /// called — `createReimbursement(...)`/`deleteReimbursement(_:)` already
    /// keep `reimbursements` in sync after a write, so a caller only needs
    /// this for the initial load or an explicit retry after `.failed`.
    func loadReimbursements() async {
        guard let advance else { return }
        do {
            reimbursements = .loaded(try await client.reimbursements(advanceID: advance.id))
        } catch {
            reimbursements = .failed
        }
    }

    /// Record a reimbursement against this transaction's advance — a manual
    /// cash entry, or a link to an incoming transaction.
    ///
    /// A no-op without an advance. On success, the advance is re-fetched
    /// (`reimbursed`/`outstanding`/`status` all follow from the sum of
    /// reimbursements, computed server-side — this response alone does not
    /// carry them) and published via `onAdvanceChange`. When a transaction
    /// was linked, its `role` becomes `reimbursement` server-side; that row
    /// is re-fetched too and handed to `onUpdate`, the same two-row
    /// discipline as `unlinkTransfer()`.
    ///
    /// Parameters
    /// ----------
    /// amount:
    ///     The amount paid back, a positive magnitude in the advance's
    ///     currency.
    /// transactionID:
    ///     The incoming transaction to link, or `nil` for cash.
    /// participantID:
    ///     The participant to attribute this reimbursement to (ADR 0012), or
    ///     `nil` to leave it unattributed.
    /// note:
    ///     Optional free-text note.
    func createReimbursement(
        amount: Int, transactionID: UUID?, participantID: UUID?, note: String?
    ) async {
        guard let advance, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            _ = try await client.createReimbursement(
                advanceID: advance.id,
                CreateReimbursementRequest(
                    amount: amount, transactionID: transactionID, participantID: participantID,
                    note: note
                )
            )
            let refreshedAdvance = try await client.advance(id: advance.id)
            self.advance = refreshedAdvance
            onAdvanceChange(refreshedAdvance)
            reimbursements = .loaded(try await client.reimbursements(advanceID: advance.id))
            if let transactionID {
                let refreshedLinked = try await client.transaction(id: transactionID)
                onUpdate(refreshedLinked)
            }
            onDashboardStale()
            successTick += 1
        } catch {
            actionFailure = .generic
        }
    }

    /// Delete a previously recorded reimbursement.
    ///
    /// A no-op without an advance. On success, both the advance (its
    /// `reimbursed`/`outstanding`/`status` all shrink server-side) and the
    /// reimbursements list are re-fetched and published; when the deleted
    /// reimbursement had linked a transaction, that transaction reverted to
    /// `role == .personal` server-side, so it is re-fetched too and handed to
    /// `onUpdate` — the same two-effect discipline as
    /// `createReimbursement(...)`, just undoing it.
    ///
    /// Parameters
    /// ----------
    /// reimbursement:
    ///     The reimbursement to delete.
    func deleteReimbursement(_ reimbursement: ReimbursementResponse) async {
        guard let advance, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await client.deleteReimbursement(advanceID: advance.id, id: reimbursement.id)
            let refreshedAdvance = try await client.advance(id: advance.id)
            self.advance = refreshedAdvance
            onAdvanceChange(refreshedAdvance)
            reimbursements = .loaded(try await client.reimbursements(advanceID: advance.id))
            if let transactionID = reimbursement.transactionID {
                let refreshedLinked = try await client.transaction(id: transactionID)
                onUpdate(refreshedLinked)
            }
            onDashboardStale()
        } catch {
            actionFailure = .generic
        }
    }

    /// Shared shape for `writeOffAdvance()` and `reopenAdvance()`: guard
    /// against overlap and a missing advance, run the write, publish the
    /// updated advance, and notify `onAdvanceChange` — or record
    /// `actionFailure` and leave `advance` untouched on failure. Neither
    /// action changes the transaction's `role`, so `onUpdate` is not called
    /// here (unlike `performUpdate`).
    ///
    /// Parameters
    /// ----------
    /// write:
    ///     The advance write to perform, given the client and this advance's
    ///     id.
    private func performAdvanceUpdate(
        _ write: (any APIClientProtocol, UUID) async throws -> AdvanceResponse
    ) async {
        guard let advance, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            let updated = try await write(client, advance.id)
            self.advance = updated
            onAdvanceChange(updated)
            onDashboardStale()
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
            onDashboardStale()
            successTick += 1
        } catch {
            actionFailure = .generic
        }
    }

    /// Assign this transaction to an event, replacing any previous one.
    ///
    /// A no-op when `eventID` is already this transaction's event. The
    /// backend refuses a second event with `409` (`docs/domain.md` §Event:
    /// membership is exclusive), so switching is genuinely two calls —
    /// `unassignTransaction` from the old event, then `assignTransaction` to
    /// the new one. If the second call fails, the final re-fetch still runs,
    /// so the view reflects the transaction's real (now event-less) state
    /// rather than the one this call hoped for.
    ///
    /// Parameters
    /// ----------
    /// eventID:
    ///     The event to assign this transaction to.
    func assignToEvent(_ eventID: UUID) async {
        guard transaction.eventID != eventID else { return }
        let previousEventID = transaction.eventID
        await performEventMembershipUpdate { client, transactionID in
            if let previousEventID {
                try await client.unassignTransaction(eventID: previousEventID, transactionID: transactionID)
            }
            try await client.assignTransaction(eventID: eventID, transactionID: transactionID)
        }
    }

    /// Remove this transaction from its current event, if it has one.
    ///
    /// A no-op without an event.
    func removeFromEvent() async {
        guard let eventID = transaction.eventID else { return }
        await performEventMembershipUpdate { client, transactionID in
            try await client.unassignTransaction(eventID: eventID, transactionID: transactionID)
        }
    }

    /// Shared shape for `assignToEvent(_:)` and `removeFromEvent()`: guard
    /// against overlap, run the write, re-fetch the row, publish it, and
    /// notify `onUpdate` — or record `actionFailure`. Unlike `performUpdate`,
    /// this never calls `onDashboardStale` (event membership never touches
    /// `role`/`effectiveAmount`), maps `APIError.badStatus` to the two
    /// reasons the endpoint actually distinguishes (mirroring
    /// `EventDetailViewModel.performMembershipUpdate`), and **always
    /// re-fetches, even on failure** — `assignToEvent(_:)`'s
    /// unassign-then-assign sequence can fail on the second call after the
    /// first already succeeded, leaving the transaction genuinely
    /// event-less; refetching shows that real state instead of a stale
    /// chip for an event membership that no longer exists.
    ///
    /// Parameters
    /// ----------
    /// write:
    ///     The membership write to perform, given the client and this
    ///     transaction's id.
    private func performEventMembershipUpdate(
        _ write: (any APIClientProtocol, UUID) async throws -> Void
    ) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await write(client, transaction.id)
        } catch APIError.badStatus(409) {
            actionFailure = .transactionInAnotherEvent
        } catch APIError.badStatus(422) {
            actionFailure = .mixedCurrency
        } catch {
            actionFailure = .generic
        }

        if let refreshed = try? await client.transaction(id: transaction.id) {
            transaction = refreshed
            onUpdate(refreshed)
        }
    }
}
