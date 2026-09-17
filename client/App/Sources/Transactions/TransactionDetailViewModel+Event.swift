import Foundation
import TraccioCore

/// Assigning this transaction to an event, or removing it from one.
extension TransactionDetailViewModel {
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
