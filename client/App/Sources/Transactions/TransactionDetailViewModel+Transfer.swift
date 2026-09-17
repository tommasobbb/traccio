import Foundation
import TraccioCore

/// Loading the counterpart leg of a confirmed transfer, and unlinking it.
extension TransactionDetailViewModel {
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
}
