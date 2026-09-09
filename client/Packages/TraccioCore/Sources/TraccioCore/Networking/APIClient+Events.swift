import Foundation

// Event endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient {
    /// Fetch the caller's events.
    ///
    /// Returns
    /// -------
    /// The decoded events from `GET /events`, oldest first. Each carries the
    /// server-derived `total`/`memberCount` — the client never recomputes
    /// these (an event is a reporting lens, not a role:
    /// `docs/domain.md` §Event).
    public func events() async throws -> [EventResponse] {
        let envelope: EventsResponse = try await get("events")
        return envelope.events
    }

    /// Fetch one event by id.
    ///
    /// Mirrors `GET /events/{id}`, `200` with the event. Used to re-fetch an
    /// event's derived `total`/`memberCount` after assigning or unassigning a
    /// member, without re-fetching the whole list. A `404` if the event is
    /// unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded event.
    public func event(id: UUID) async throws -> EventResponse {
        try await get("events/\(id.uuidString)")
    }

    /// Suggested un-grouped transactions dated within an event's range
    /// (ADR 0028).
    ///
    /// Mirrors `GET /events/{id}/suggestions`, `200` with the candidates —
    /// un-grouped transactions whose date falls in `[start_date, end_date]`,
    /// most recent first. Empty when the event has no full date range. The
    /// client still assigns each one with an explicit `assignTransaction` —
    /// this only *suggests*. A `404` if the event is unknown or not the
    /// caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event whose date range drives the suggestion.
    ///
    /// Returns
    /// -------
    /// Candidate transactions (empty if none / no date range).
    public func eventSuggestions(id: UUID) async throws -> [TransactionResponse] {
        let envelope: TransactionsResponse = try await get(
            "events/\(id.uuidString)/suggestions"
        )
        return envelope.transactions
    }

    /// Fetch an event's spending broken down by category (ADR 0028).
    ///
    /// Mirrors `GET /events/{id}/summary`, `200` with the breakdown. The
    /// backend reuses its own dashboard aggregation over the event's
    /// members, so `byCategory` is the same shape `dashboardSummary` returns.
    /// A `404` if the event is unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event whose breakdown to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded breakdown; all-zero and `currency: nil` for an empty event.
    public func eventSummary(id: UUID) async throws -> EventSummaryResponse {
        try await get("events/\(id.uuidString)/summary")
    }

    /// List an event's member transactions, most recent first.
    ///
    /// Mirrors `GET /events/{id}/transactions`, `200` with the transactions —
    /// unpaginated, since an event's members are a bounded set (unlike
    /// `transactions(accountID:limit:offset:)`'s unbounded pool). A `404` if
    /// the event is unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event whose members to list.
    ///
    /// Returns
    /// -------
    /// The event's member transactions (empty if none).
    public func eventTransactions(id: UUID) async throws -> [TransactionResponse] {
        let envelope: TransactionsResponse = try await get("events/\(id.uuidString)/transactions")
        return envelope.transactions
    }

    /// Create an event.
    ///
    /// Mirrors `POST /events`, `201 Created` with the created event. Starts
    /// `active`, with no members and a zero total.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The event's name and optional date range.
    ///
    /// Returns
    /// -------
    /// The created event.
    public func createEvent(_ request: CreateEventRequest) async throws -> EventResponse {
        try await post("events", body: request)
    }

    /// Edit an event's name, emoji, colour and date range (ADR 0027).
    ///
    /// Mirrors `POST /events/{id}`, `200` with the updated event. A full
    /// replace of the editable fields — `status` and membership are
    /// untouched. A `404` if the event is unknown or not the caller's; a
    /// `422` if `emoji` is not a single emoji.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to edit.
    /// request:
    ///     The new name, emoji, colour and dates.
    ///
    /// Returns
    /// -------
    /// The updated event, with its refreshed derived total.
    public func updateEvent(id: UUID, _ request: UpdateEventRequest) async throws -> EventResponse {
        try await post("events/\(id.uuidString)", body: request)
    }

    /// Delete an event, keeping its member transactions.
    ///
    /// Mirrors `DELETE /events/{id}`, `204 No Content` on success. Removes
    /// only the grouping — every member's `event_id` is cleared server-side,
    /// the transactions themselves are untouched. A `404` if the event is
    /// unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to delete.
    public func deleteEvent(id: UUID) async throws {
        try await delete("events/\(id.uuidString)")
    }

    /// Close an event.
    ///
    /// Mirrors `POST /events/{id}/close`, `200` with the updated event —
    /// `status` becomes `closed`. A `404` if the event is unknown or not the
    /// caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to close.
    ///
    /// Returns
    /// -------
    /// The updated event.
    public func closeEvent(id: UUID) async throws -> EventResponse {
        try await post("events/\(id.uuidString)/close")
    }

    /// Reopen a closed event.
    ///
    /// Mirrors `POST /events/{id}/reopen`, `200` with the updated event —
    /// `status` becomes `active`. A `404` if the event is unknown or not the
    /// caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to reopen.
    ///
    /// Returns
    /// -------
    /// The updated event.
    public func reopenEvent(id: UUID) async throws -> EventResponse {
        try await post("events/\(id.uuidString)/reopen")
    }

    /// Group a transaction under an event.
    ///
    /// Mirrors `POST /events/{id}/transactions`, `204 No Content` on success.
    /// Sets the transaction's `event_id` server-side — membership is a
    /// reporting lens and never changes its `role` or `effectiveAmount`. A
    /// `404` if the event or transaction is unknown or not the caller's; a
    /// `409` if the transaction already belongs to a *different* event (one
    /// event per transaction); re-assigning to the same event is idempotent.
    ///
    /// Parameters
    /// ----------
    /// eventID:
    ///     The event to group the transaction under.
    /// transactionID:
    ///     The transaction to assign. Must belong to the caller.
    public func assignTransaction(eventID: UUID, transactionID: UUID) async throws {
        try await post(
            "events/\(eventID.uuidString)/transactions",
            body: AssignTransactionRequest(transactionID: transactionID)
        )
    }

    /// Remove a transaction from an event.
    ///
    /// Mirrors `DELETE /events/{id}/transactions/{transaction_id}`, `204 No
    /// Content` on success. A `404` if the event is unknown or not the
    /// caller's, or if the transaction is not currently a member.
    ///
    /// Parameters
    /// ----------
    /// eventID:
    ///     The event to remove the transaction from.
    /// transactionID:
    ///     The transaction to unassign.
    public func unassignTransaction(eventID: UUID, transactionID: UUID) async throws {
        try await delete("events/\(eventID.uuidString)/transactions/\(transactionID.uuidString)")
    }
}
