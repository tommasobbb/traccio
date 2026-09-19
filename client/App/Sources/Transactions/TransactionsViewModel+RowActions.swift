import Foundation
import TraccioCore

/// Mark-as-advance and manual-movement edit/delete — moved here from
/// `TransactionDetailViewModel+Advance.swift`/`+ManualEdit.swift` (the latter
/// deleted) when these became row-level actions
/// (`docs/decisions/0036-movimenti-row-actions.md`). Shares
/// `isUpdatingRow`/`rowActionFailure` with
/// `TransactionsViewModel+Category.swift` — only one row-action sheet or
/// dialog can be open at a time, so there is never real overlap to
/// distinguish.
extension TransactionsViewModel {
    /// Create an advance on `transactionID` — the explicit user action from
    /// `CreateAdvanceSheet`, opened via the row's context menu.
    ///
    /// On success, both the created advance and the refreshed transaction
    /// (its `role` is now `advance`, `effectiveAmount` now `ownShare`) are
    /// published: the row is swapped in via `replace(_:)` and
    /// `updateAdvance(_:for:)` keeps `advancesByTransactionID` in sync — an
    /// advance is not part of `TransactionResponse`, so `replace(_:)` alone
    /// cannot carry it. Does not reuse `performRowUpdate(for:_:)`: that
    /// helper's write returns nothing, but this call also needs the created
    /// `AdvanceResponse` itself.
    ///
    /// Parameters
    /// ----------
    /// ownShare:
    ///     The user's declared share, a positive magnitude in the
    ///     transaction's currency. The backend validates the range; an
    ///     out-of-range value surfaces as `rowActionFailure`.
    /// participants:
    ///     People who owe the user back; may be empty.
    /// transactionID:
    ///     The transaction to create the advance on.
    ///
    /// Returns
    /// -------
    /// `true` if the advance was created, `false` otherwise (having recorded
    /// `rowActionFailure`).
    @discardableResult
    func createAdvance(
        ownShare: Int, participants: [ParticipantRequest], for transactionID: UUID
    ) async -> Bool {
        guard beginRowAction() else { return false }

        do {
            let created = try await client.createAdvance(
                CreateAdvanceRequest(
                    transactionID: transactionID, ownShare: ownShare, participants: participants
                )
            )
            let refreshed = try await client.transaction(id: transactionID)
            replace(refreshed)
            updateAdvance(created, for: transactionID)
            endRowAction(failure: nil)
            markRowActionSucceeded()
            return true
        } catch {
            endRowAction(failure: .generic)
            return false
        }
    }

    /// Edit `transactionID`'s amount/currency/value-date/description (ADR
    /// 0020), then swap the refreshed row in via `replace(_:)`.
    ///
    /// Only valid for a movement on a manual account; the backend answers
    /// `409 transaction_not_manual` otherwise, surfaced as `.generic` — the
    /// row's context menu only offers "Modifica" for a manual movement
    /// (`TransactionRow.Actions`), so that path is effectively unreachable.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The movement to edit.
    /// amount:
    ///     New signed value in minor units.
    /// currency:
    ///     New ISO 4217 code of `amount`.
    /// valueDate:
    ///     New value date.
    /// description:
    ///     New description text.
    ///
    /// Returns
    /// -------
    /// `true` if the edit succeeded, `false` otherwise (having recorded
    /// `rowActionFailure`).
    @discardableResult
    func editManualTransaction(
        transactionID: UUID, amount: Int, currency: String, valueDate: Date, description: String
    ) async -> Bool {
        await performRowUpdate(for: transactionID) {
            _ = try await $0.editManualTransaction(
                id: $1,
                EditManualTransactionRequest(
                    amount: amount, currency: currency, valueDate: valueDate,
                    description: description
                )
            )
        }
    }

    /// Delete `transactionID`, a manual movement (ADR 0020), and drop its
    /// row via `remove(id:)`.
    ///
    /// A `409 transaction_in_use` surfaces as `.transactionInUse` — the
    /// movement is a transfer/advance/reimbursement leg and must be unlinked
    /// first; any other failure as `.generic`. Does not reuse
    /// `performRowUpdate(for:_:)` (nothing to re-fetch — the row is gone).
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The movement to delete.
    ///
    /// Returns
    /// -------
    /// `true` if the movement was deleted, `false` otherwise (having
    /// recorded `rowActionFailure`).
    @discardableResult
    func deleteManualTransaction(_ transactionID: UUID) async -> Bool {
        guard beginRowAction() else { return false }

        do {
            try await client.deleteManualTransaction(id: transactionID)
            remove(id: transactionID)
            endRowAction(failure: nil)
            markRowActionSucceeded()
            return true
        } catch APIError.badStatus(409) {
            endRowAction(failure: .transactionInUse)
            return false
        } catch {
            endRowAction(failure: .generic)
            return false
        }
    }
}
