import Foundation
import TraccioCore

/// Loading reimbursement candidates and recorded reimbursements, and
/// recording/deleting a reimbursement against this transaction's advance.
extension TransactionDetailViewModel {
    /// Fetch this transaction's reimbursement candidates, if not already
    /// loaded.
    ///
    /// A no-op when `reimbursementCandidates` is already non-empty. Failure
    /// leaves it empty; `AddReimbursementSheet` still works for a cash-only
    /// entry. The account lookup is fetched in the same pass so a candidate
    /// row can name its account; a failure there only costs the label.
    func loadReimbursementCandidatesIfNeeded() async {
        guard reimbursementCandidates.isEmpty else { return }
        guard let fetched = try? await client.transactions(filter: .none, limit: 100, offset: 0)
        else { return }
        reimbursementCandidates = fetched.filter {
            $0.role == .personal && $0.amount > 0 && $0.currency == transaction.currency
        }
        if let accounts = try? await client.accounts() {
            reimbursementCandidateAccounts = Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, $0) }
            )
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
}
