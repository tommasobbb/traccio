import Foundation
import TraccioCore

/// Editing and deleting a manual movement (ADR 0020) — the account itself is
/// manual, not just this one entry, so there is no bank sync to conflict with.
extension TransactionDetailViewModel {
    /// Edit this manual movement's amount/currency/value-date/description
    /// (ADR 0020), then re-fetch it.
    ///
    /// Only valid for a movement on a manual account; the backend answers
    /// `409 transaction_not_manual` otherwise, surfaced as `.generic` — the
    /// view only shows the edit affordance for a manual row, so that path is
    /// effectively unreachable. Reuses `performUpdate`, so `onUpdate` /
    /// `onDashboardStale` / `successTick` all fire on success.
    ///
    /// Parameters
    /// ----------
    /// amount:
    ///     New signed value in minor units.
    /// currency:
    ///     New ISO 4217 code of `amount`.
    /// valueDate:
    ///     New value date.
    /// description:
    ///     New description text.
    func editManualTransaction(
        amount: Int, currency: String, valueDate: Date, description: String
    ) async {
        await performUpdate {
            _ = try await $0.editManualTransaction(
                id: $1,
                EditManualTransactionRequest(
                    amount: amount, currency: currency, valueDate: valueDate,
                    description: description
                )
            )
        }
    }

    /// Delete this manual movement (ADR 0020).
    ///
    /// On success `onDelete` fires with the id (so the list drops the row)
    /// and `onDashboardStale` (a movement leaving changes the totals); the
    /// view dismisses itself. A `409 transaction_in_use` surfaces as
    /// `.transactionInUse` — the movement is a transfer/advance/reimbursement
    /// leg and must be unlinked first; any other failure is `.generic`. Does
    /// not reuse `performUpdate` (nothing to re-fetch — the row is gone).
    func deleteManualTransaction() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await client.deleteManualTransaction(id: transaction.id)
            onDelete(transaction.id)
            onDashboardStale()
            successTick += 1
        } catch APIError.badStatus(409) {
            actionFailure = .transactionInUse
        } catch {
            actionFailure = .generic
        }
    }
}
