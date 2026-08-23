import Foundation

extension TransactionResponse {
    /// The date this transaction is shown under: `bookedAt` when settled,
    /// else `valueDate`, else `nil`.
    ///
    /// Deliberately mirrors the backend's `coalesce(booked_at, value_date)`
    /// expression (`db/repositories.py::list_transactions`), which is also
    /// what `GET /transactions` is already ordered by — so the client's
    /// grouping can never disagree with the server's ordering. This is a
    /// *display* date, not a derived financial value; it plays no part in
    /// `effectiveAmount`.
    public var effectiveDate: Date? {
        bookedAt ?? valueDate
    }
}
