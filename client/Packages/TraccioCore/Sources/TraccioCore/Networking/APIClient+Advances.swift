import Foundation

/// Advance and reimbursement endpoints — one slice of `APIClientProtocol`.
public protocol AdvancesAPI: Sendable {
    func advances(status: AdvanceStatus?) async throws -> AdvancesResponse
    func advance(id: UUID) async throws -> AdvanceResponse
    func createAdvance(_ request: CreateAdvanceRequest) async throws -> AdvanceResponse
    func deleteAdvance(id: UUID) async throws
    func writeOffAdvance(id: UUID) async throws -> AdvanceResponse
    func reopenAdvance(id: UUID) async throws -> AdvanceResponse
    func createReimbursement(
        advanceID: UUID, _ request: CreateReimbursementRequest
    ) async throws -> ReimbursementResponse
    func reimbursements(advanceID: UUID) async throws -> [ReimbursementResponse]
    func deleteReimbursement(advanceID: UUID, id: UUID) async throws
}

// Advance and reimbursement endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient: AdvancesAPI {
    /// Fetch the caller's advances and the cross-advance summary.
    ///
    /// Parameters
    /// ----------
    /// status:
    ///     When non-`nil`, only advances in that lifecycle state come back in
    ///     `advances`. The `summary` is always computed over every advance
    ///     server-side, so it does not move when this narrows the rows
    ///     (ADR 0026).
    ///
    /// Returns
    /// -------
    /// The decoded `GET /advances` envelope: the rows (oldest first) plus
    /// `summary.byPerson` / `summary.totals`. Every amount is server-derived —
    /// the client never recomputes these.
    public func advances(status: AdvanceStatus? = nil) async throws -> AdvancesResponse {
        let query = status.map { [URLQueryItem(name: "status", value: $0.rawValue)] } ?? []
        return try await get("advances", query: query)
    }

    /// Fetch one advance by id.
    ///
    /// Mirrors `GET /advances/{id}`. Used to re-fetch an advance's derived
    /// `reimbursed`/`outstanding`/`status` after recording a reimbursement,
    /// without re-fetching the whole list.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded advance.
    public func advance(id: UUID) async throws -> AdvanceResponse {
        try await get("advances/\(id.uuidString)")
    }

    /// Create an advance on a transaction — the explicit user action that
    /// marks money laid out on someone else's behalf.
    ///
    /// Mirrors `POST /advances`, `201 Created` with the created advance. Sets
    /// the transaction's `role` to `advance` server-side; the caller
    /// re-fetches it via `transaction(id:)` to observe the new
    /// `effectiveAmount`, same discipline as
    /// `confirmTransfer(outgoingID:incomingID:)`.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The transaction, the user's own share, and optional participants.
    ///
    /// Returns
    /// -------
    /// The created advance.
    public func createAdvance(_ request: CreateAdvanceRequest) async throws -> AdvanceResponse {
        try await post("advances", body: request)
    }

    /// Delete an advance and revert its transaction to `personal`.
    ///
    /// Mirrors `DELETE /advances/{id}`, `204 No Content` on success. The
    /// caller re-fetches the transaction via `transaction(id:)` to observe
    /// its restored `effectiveAmount`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to delete.
    public func deleteAdvance(id: UUID) async throws {
        try await delete("advances/\(id.uuidString)")
    }

    /// Write off an advance that will never be reimbursed.
    ///
    /// Mirrors `POST /advances/{id}/write-off`, `200` with the updated
    /// advance — `status` becomes `writtenOff` regardless of what is still
    /// outstanding.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to write off.
    ///
    /// Returns
    /// -------
    /// The updated advance.
    public func writeOffAdvance(id: UUID) async throws -> AdvanceResponse {
        try await post("advances/\(id.uuidString)/write-off")
    }

    /// Reopen a previously written-off advance.
    ///
    /// Mirrors `POST /advances/{id}/reopen`, `200` with the updated advance —
    /// the inverse of `writeOffAdvance(id:)`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to reopen.
    ///
    /// Returns
    /// -------
    /// The updated advance.
    public func reopenAdvance(id: UUID) async throws -> AdvanceResponse {
        try await post("advances/\(id.uuidString)/reopen")
    }

    /// Record a reimbursement against an advance — either a manual cash entry
    /// or a link to an existing incoming transaction.
    ///
    /// Mirrors `POST /advances/{id}/reimbursements`, `201 Created` with the
    /// created reimbursement. A linked transaction's `role` becomes
    /// `reimbursement` server-side; the caller re-fetches it via
    /// `transaction(id:)` to observe the new `effectiveAmount`. The advance's
    /// derived `reimbursed`/`outstanding`/`status` are not on this response —
    /// re-fetch via `advance(id:)`.
    ///
    /// Parameters
    /// ----------
    /// advanceID:
    ///     The advance being paid back.
    /// request:
    ///     The amount, optional linked transaction, and optional note.
    ///
    /// Returns
    /// -------
    /// The created reimbursement.
    public func createReimbursement(
        advanceID: UUID,
        _ request: CreateReimbursementRequest
    ) async throws -> ReimbursementResponse {
        try await post("advances/\(advanceID.uuidString)/reimbursements", body: request)
    }

    /// Fetch an advance's reimbursements, oldest first.
    ///
    /// Mirrors `GET /advances/{id}/reimbursements`.
    ///
    /// Parameters
    /// ----------
    /// advanceID:
    ///     The advance whose reimbursements to list.
    ///
    /// Returns
    /// -------
    /// The decoded reimbursements (empty if none).
    public func reimbursements(advanceID: UUID) async throws -> [ReimbursementResponse] {
        let envelope: ReimbursementsResponse = try await get(
            "advances/\(advanceID.uuidString)/reimbursements"
        )
        return envelope.reimbursements
    }

    /// Delete a reimbursement and revert its linked transaction to `personal`,
    /// if it had one.
    ///
    /// Mirrors `DELETE /advances/{advanceID}/reimbursements/{id}`,
    /// `204 No Content` on success. The caller re-fetches the advance via
    /// `advance(id:)` to observe the reduced `reimbursed`/`outstanding`, and —
    /// when the deleted reimbursement carried a `transactionID` — that
    /// transaction via `transaction(id:)` to observe its restored
    /// `effectiveAmount`.
    ///
    /// Parameters
    /// ----------
    /// advanceID:
    ///     The advance the reimbursement belongs to.
    /// id:
    ///     The reimbursement to delete.
    public func deleteReimbursement(advanceID: UUID, id: UUID) async throws {
        try await delete("advances/\(advanceID.uuidString)/reimbursements/\(id.uuidString)")
    }
}
