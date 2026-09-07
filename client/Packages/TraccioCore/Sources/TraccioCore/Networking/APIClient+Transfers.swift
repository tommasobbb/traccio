import Foundation

// Transfer endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient {
    /// Suggest transfers among the caller's transactions.
    ///
    /// Mirrors `GET /transfers/suggestions`. Detection only *suggests* — see
    /// `confirmTransfer(outgoingID:incomingID:)` for the write that acts on
    /// one. Each suggestion embeds both legs' full `TransactionResponse`, so
    /// rendering one needs no follow-up request per leg.
    ///
    /// Returns
    /// -------
    /// The suggested transfers, most confident first (empty if none).
    public func transferSuggestions() async throws -> [TransferSuggestionResponse] {
        let envelope: TransferSuggestionsResponse = try await get("transfers/suggestions")
        return envelope.suggestions
    }

    /// Fetch the caller's confirmed transfers, oldest first.
    ///
    /// Mirrors `GET /transfers`.
    ///
    /// Returns
    /// -------
    /// The decoded transfers.
    public func transfers() async throws -> [TransferResponse] {
        let envelope: TransfersResponse = try await get("transfers")
        return envelope.transfers
    }

    /// Confirm two transactions as a transfer — the explicit user action that
    /// turns a suggestion into a persisted link.
    ///
    /// Mirrors `POST /transfers/confirm`, which sets both legs' `role` to
    /// `transfer` and returns the created transfer. Both legs'
    /// `effectiveAmount` becomes zero as a result; the caller re-fetches them
    /// via `transaction(id:)` to observe that, same discipline as
    /// `confirmCategory(transactionID:categoryID:)`.
    ///
    /// Parameters
    /// ----------
    /// outgoingID:
    ///     Two-sided: the negative leg. Funded payment: the funding leg (set to
    ///     `role == .funding`).
    /// incomingID:
    ///     Two-sided: the positive leg. Funded payment: the funded leg — the
    ///     real expense, left `.personal`.
    /// kind:
    ///     `.twoSided` zeroes both legs; `.fundedPayment` zeroes only
    ///     `outgoingID`.
    ///
    /// Returns
    /// -------
    /// The created transfer.
    public func confirmTransfer(
        outgoingID: UUID, incomingID: UUID, kind: TransferKind
    ) async throws -> TransferResponse {
        try await post(
            "transfers/confirm",
            body: ConfirmTransferRequest(
                kind: kind, outgoingTransactionID: outgoingID, incomingTransactionID: incomingID
            )
        )
    }

    /// Reject a suggested pair so it is not suggested again.
    ///
    /// Mirrors `POST /transfers/reject`, `204 No Content` on success.
    /// Idempotent on the backend: rejecting the same pair twice changes
    /// nothing.
    ///
    /// Parameters
    /// ----------
    /// outgoingID:
    ///     One leg of the rejected pair (the suggestion's outgoing leg).
    /// incomingID:
    ///     The other leg of the rejected pair (the suggestion's incoming leg).
    public func rejectTransfer(outgoingID: UUID, incomingID: UUID) async throws {
        try await post(
            "transfers/reject",
            body: RejectTransferRequest(
                outgoingTransactionID: outgoingID, incomingTransactionID: incomingID
            )
        )
    }

    /// Delete a confirmed transfer and revert both legs to `personal`.
    ///
    /// Mirrors `DELETE /transfers/{id}`, `204 No Content` on success. The
    /// caller re-fetches both legs via `transaction(id:)` to observe their
    /// restored `effectiveAmount`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transfer to delete.
    public func deleteTransfer(id: UUID) async throws {
        try await delete("transfers/\(id.uuidString)")
    }
}
