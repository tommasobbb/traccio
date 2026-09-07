import Foundation

// Transaction endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient {
    /// Fetch one transaction by id.
    ///
    /// Mirrors `GET /transactions/{id}`. Exists so a caller can re-fetch a
    /// single row's server-derived `effectiveAmount`/`effectiveCategoryID`
    /// after a write (e.g. confirming a category) without re-paginating the
    /// whole list — the backend still owns every derived value
    /// (`client/CLAUDE.md`).
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded transaction.
    public func transaction(id: UUID) async throws -> TransactionResponse {
        try await get("transactions/\(id.uuidString)")
    }

    /// Confirm a category on a transaction — the explicit user action.
    ///
    /// Mirrors `POST /transactions/{id}/category`, which returns `204 No
    /// Content` on success: the caller re-fetches via `transaction(id:)` to
    /// observe the new `effectiveCategoryID` rather than this method
    /// returning or inferring one.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to categorize.
    /// categoryID:
    ///     The category to confirm; must belong to the caller.
    public func confirmCategory(transactionID: UUID, categoryID: UUID) async throws {
        try await post(
            "transactions/\(transactionID.uuidString)/category",
            body: ConfirmCategoryRequest(categoryID: categoryID)
        )
    }

    /// Clear a transaction's confirmed category, falling back to any
    /// suggestion.
    ///
    /// Mirrors `POST`'s sibling `DELETE /transactions/{id}/category`, also
    /// `204 No Content`. Idempotent on the backend: clearing an already-clear
    /// transaction still succeeds.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to clear.
    public func clearCategory(transactionID: UUID) async throws {
        try await delete("transactions/\(transactionID.uuidString)/category")
    }

    /// Create a user-entered movement on a manual account (ADR 0020).
    ///
    /// Mirrors `POST /transactions`, `201` with the created transaction (it
    /// is always `booked`, `role == .personal`). A `404` if the account (or
    /// the optional category) is unknown or not the caller's; a `409
    /// account_not_manual` if the account is a synced one.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The movement's account, amount, currency, value date, description,
    ///     and optional category.
    ///
    /// Returns
    /// -------
    /// The created transaction, with the same derived fields
    /// `GET /transactions` returns.
    public func createManualTransaction(
        _ request: CreateManualTransactionRequest
    ) async throws -> TransactionResponse {
        try await post("transactions", body: request)
    }

    /// Edit a user-entered movement on a manual account (ADR 0020).
    ///
    /// Mirrors `POST /transactions/{id}/edit`, `200` with the transaction
    /// after the edit. A `404` if the transaction is unknown or not the
    /// caller's; a `409 transaction_not_manual` if it is on a synced account.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to edit.
    /// request:
    ///     The new movement fields (amount, currency, value date,
    ///     description).
    ///
    /// Returns
    /// -------
    /// The transaction after the edit.
    public func editManualTransaction(
        id: UUID, _ request: EditManualTransactionRequest
    ) async throws -> TransactionResponse {
        try await post("transactions/\(id.uuidString)/edit", body: request)
    }

    /// Delete a user-entered movement on a manual account (ADR 0020).
    ///
    /// Mirrors `DELETE /transactions/{id}`, `204`. A `404` if the transaction
    /// is unknown or not the caller's; a `409 transaction_not_manual` if it
    /// is on a synced account; a `409 transaction_in_use` if it is a leg of a
    /// transfer, advance, or reimbursement — unlink that first.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to delete.
    public func deleteManualTransaction(id: UUID) async throws {
        try await delete("transactions/\(id.uuidString)")
    }

    /// Fetch a page of the caller's transactions, most recent first.
    ///
    /// Mirrors `GET /transactions` (`docs/api/openapi.json`). Ordering,
    /// pagination bounds, and every filter all live on the backend; this
    /// method only shapes the request and decodes the result — filtering is
    /// never applied client-side against an already-fetched page (see
    /// `TransactionFilter`).
    ///
    /// Parameters
    /// ----------
    /// filter:
    ///     Which transactions to include. `.none` (the default) returns
    ///     every account, every category.
    /// limit:
    ///     Page size; the backend validates `1...200` and defaults to `50`.
    /// offset:
    ///     Number of rows to skip, for paging past the first page.
    ///
    /// Returns
    /// -------
    /// The decoded page of transactions, most recent first.
    public func transactions(
        filter: TransactionFilter = .none,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [TransactionResponse] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ] + filter.queryItems
        let envelope: TransactionsResponse = try await get("transactions", query: query)
        return envelope.transactions
    }
}
