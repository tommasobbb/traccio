import Foundation
import Observation
import TraccioCore

/// Drives `EventDetailView`: the event's members, closing/reopening,
/// assigning/unassigning a transaction, and deleting the event.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`client/CLAUDE.md`): `total`/`memberCount` are server-derived
/// (`domain/events.py::event_total`). A membership write re-fetches *both*
/// the event and its members (`async let`), since assigning or unassigning a
/// transaction changes both `event`'s totals and the `members` list — unlike
/// `TransactionDetailViewModel.performUpdate`, which only ever needs to
/// re-fetch one row. Nothing here logs or prints a transaction or an event
/// name (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class EventDetailViewModel {
    /// Why a write failed, for the view to surface. Carries only a
    /// status-derived reason, never the response body
    /// (`.claude/rules/data-safety.md`).
    enum ActionFailure: Equatable {
        /// `POST /events/{id}/transactions` refused (`409`) because the
        /// transaction already belongs to a *different* event.
        case transactionInAnotherEvent
        /// `POST /events/{id}/transactions` refused (`422
        /// mixed_currency`) because the transaction's currency does not
        /// match the event's other members.
        case mixedCurrency
        case generic
    }

    /// The event shown, refreshed in place after a successful status or
    /// membership change.
    private(set) var event: EventResponse
    /// The event's member transactions, most recent first.
    private(set) var members: [TransactionResponse] = []
    /// Best-effort candidates for "Aggiungi movimenti": a page of the
    /// caller's transactions, fetched once and filtered against `members` by
    /// `availableCandidates`. Failure leaves it empty; the sheet degrades to
    /// showing nothing to add — same posture as
    /// `TransactionDetailViewModel.loadReimbursementCandidatesIfNeeded()`.
    private(set) var candidates: [TransactionResponse] = []
    /// Set while a close/reopen/assign/unassign/delete call is in flight, to
    /// disable the screen's controls rather than let two actions race.
    private(set) var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?
    /// Set once `deleteEvent()` succeeds, so the view can dismiss itself —
    /// the event no longer exists, unlike every other write here, which
    /// leaves the screen showing the (refreshed) same event.
    private(set) var wasDeleted = false

    /// Client used to reach the backend.
    private let client: any APIClientProtocol
    /// Called with the refreshed event after a successful close/reopen/
    /// assign/unassign, so the caller (`EventsViewModel.replace(_:)`) can
    /// update the Eventi list row without a full reload.
    private let onEventChange: (EventResponse) -> Void
    /// Called with this event's id after a successful delete, so the caller
    /// (`EventsViewModel.remove(id:)`) can drop it from the list.
    private let onEventDeleted: (UUID) -> Void

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// event:
    ///     The event to show and act on.
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onEventChange:
    ///     Called with the refreshed event after a successful write.
    ///     Defaults to a no-op for previews and callers that don't need it.
    /// onEventDeleted:
    ///     Called with the event's id after a successful delete. Defaults to
    ///     a no-op.
    init(
        event: EventResponse,
        client: any APIClientProtocol = APIClient.devDefault,
        onEventChange: @escaping (EventResponse) -> Void = { _ in },
        onEventDeleted: @escaping (UUID) -> Void = { _ in }
    ) {
        self.event = event
        self.client = client
        self.onEventChange = onEventChange
        self.onEventDeleted = onEventDeleted
    }

    /// Transactions available to assign: `candidates` minus whatever is
    /// already a member, and — once the event has a currency — narrowed to
    /// that currency, so the sheet doesn't offer a candidate the backend
    /// would refuse with `mixed_currency`. A UX convenience only: the
    /// backend stays the authority (see `ActionFailure.mixedCurrency`).
    var availableCandidates: [TransactionResponse] {
        let memberIDs = Set(members.map(\.id))
        return candidates.filter { candidate in
            guard !memberIDs.contains(candidate.id) else { return false }
            guard let currency = event.currency else { return true }
            return candidate.currency == currency
        }
    }

    /// Fetch this event's member transactions.
    ///
    /// Best-effort: a failure leaves `members` at whatever it was (empty on
    /// first load), degrading to an empty-looking members card rather than
    /// failing the whole screen — the event's own summary (from `event`,
    /// seeded at `init`) still renders.
    func loadMembers() async {
        if let fetched = try? await client.eventTransactions(id: event.id) {
            members = fetched
        }
    }

    /// Fetch assignment candidates if none were loaded yet.
    ///
    /// A no-op when `candidates` is already non-empty.
    func loadCandidatesIfNeeded() async {
        guard candidates.isEmpty else { return }
        if let fetched = try? await client.transactions(accountID: nil, limit: 100, offset: 0) {
            candidates = fetched
        }
    }

    /// Assign a transaction to this event.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to assign; must belong to the caller.
    func assign(transactionID: UUID) async {
        await performMembershipUpdate(onFailure: { code in
            switch code {
            case 409: return .transactionInAnotherEvent
            case 422: return .mixedCurrency
            default: return .generic
            }
        }) { client in
            try await client.assignTransaction(eventID: self.event.id, transactionID: transactionID)
        }
    }

    /// Remove a transaction from this event.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to unassign.
    func unassign(transactionID: UUID) async {
        await performMembershipUpdate { client in
            try await client.unassignTransaction(eventID: self.event.id, transactionID: transactionID)
        }
    }

    /// Close this event.
    func closeEvent() async {
        await performStatusUpdate { try await $0.closeEvent(id: $1) }
    }

    /// Reopen a previously closed event.
    func reopenEvent() async {
        await performStatusUpdate { try await $0.reopenEvent(id: $1) }
    }

    /// Delete this event, keeping its member transactions — only the
    /// grouping is removed (`docs/domain.md` §Event).
    func deleteEvent() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await client.deleteEvent(id: event.id)
            wasDeleted = true
            onEventDeleted(event.id)
        } catch {
            actionFailure = .generic
        }
    }

    /// Shared shape for `closeEvent()`/`reopenEvent()`: guard against
    /// overlap, run the write, publish the updated event, and notify
    /// `onEventChange` — or record `actionFailure` and leave `event`
    /// untouched.
    ///
    /// Parameters
    /// ----------
    /// write:
    ///     The status write to perform, given the client and this event's
    ///     id.
    private func performStatusUpdate(
        _ write: (any APIClientProtocol, UUID) async throws -> EventResponse
    ) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            let updated = try await write(client, event.id)
            event = updated
            onEventChange(updated)
        } catch {
            actionFailure = .generic
        }
    }

    /// Shared shape for `assign(transactionID:)`/`unassign(transactionID:)`:
    /// guard against overlap, run the write, re-fetch both the event and its
    /// members on success (both change together), publish them, and notify
    /// `onEventChange` — or map the failure to an `ActionFailure` and leave
    /// `event`/`members` untouched.
    ///
    /// Parameters
    /// ----------
    /// mapFailure:
    ///     Maps a failed request's HTTP status code (`nil` for a non-HTTP
    ///     failure) to the reason the view should show. Defaults to always
    ///     reporting `.generic`.
    /// write:
    ///     The membership write to perform, given the client.
    private func performMembershipUpdate(
        onFailure mapFailure: (Int?) -> ActionFailure = { _ in .generic },
        _ write: (any APIClientProtocol) async throws -> Void
    ) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await write(client)
            async let refreshedEvent = client.event(id: event.id)
            async let refreshedMembers = client.eventTransactions(id: event.id)
            let (updatedEvent, updatedMembers) = try await (refreshedEvent, refreshedMembers)
            event = updatedEvent
            members = updatedMembers
            onEventChange(updatedEvent)
        } catch APIError.badStatus(let code) {
            actionFailure = mapFailure(code)
        } catch {
            actionFailure = mapFailure(nil)
        }
    }
}
