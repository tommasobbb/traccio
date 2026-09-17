import Foundation
import TraccioCore

/// Creating, deleting, writing off, and reopening this transaction's advance.
extension TransactionDetailViewModel {
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
}
