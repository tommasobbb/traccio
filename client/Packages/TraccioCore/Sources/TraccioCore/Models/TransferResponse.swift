import Foundation

/// One confirmed transfer, as returned by `POST /transfers/confirm` and
/// `GET /transfers`.
///
/// Mirrors the `TransferResponse` schema in `docs/api/openapi.json`. Both
/// legs already carry `role == .transfer` by the time this exists, so their
/// `effectiveAmount` is zero on `GET /transactions` — the client never
/// recomputes that, just renders it.
public struct TransferResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier of the transfer.
    public let id: UUID
    /// The negative leg (money left an account).
    public let outgoingTransactionID: UUID
    /// The positive leg (money arrived in another account).
    public let incomingTransactionID: UUID
    /// When the transfer was confirmed (timezone-aware, UTC).
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case outgoingTransactionID = "outgoing_transaction_id"
        case incomingTransactionID = "incoming_transaction_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        outgoingTransactionID: UUID,
        incomingTransactionID: UUID,
        createdAt: Date
    ) {
        self.id = id
        self.outgoingTransactionID = outgoingTransactionID
        self.incomingTransactionID = incomingTransactionID
        self.createdAt = createdAt
    }
}
