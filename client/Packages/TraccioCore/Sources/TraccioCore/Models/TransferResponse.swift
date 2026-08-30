import Foundation

/// One confirmed transfer, as returned by `POST /transfers/confirm` and
/// `GET /transfers`.
///
/// Mirrors the `TransferResponse` schema in `docs/api/openapi.json`. For a
/// `.twoSided` transfer both legs carry `role == .transfer`; for a
/// `.fundedPayment` only `outgoingTransactionID` carries `role == .funding`
/// and `incomingTransactionID` stays `.personal` (the real expense). Either
/// way the zeroed legs read `effectiveAmount == 0` on `GET /transactions` —
/// the client never recomputes that, just renders it.
public struct TransferResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier of the transfer.
    public let id: UUID
    /// Which pairing this records — see `TransferKind`.
    public let kind: TransferKind
    /// Two-sided: the negative leg. Funded payment: the funding leg
    /// (`role == .funding`).
    public let outgoingTransactionID: UUID
    /// Two-sided: the positive leg. Funded payment: the funded leg — the real
    /// expense, left `.personal`.
    public let incomingTransactionID: UUID
    /// When the transfer was confirmed (timezone-aware, UTC).
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case outgoingTransactionID = "outgoing_transaction_id"
        case incomingTransactionID = "incoming_transaction_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        kind: TransferKind,
        outgoingTransactionID: UUID,
        incomingTransactionID: UUID,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.outgoingTransactionID = outgoingTransactionID
        self.incomingTransactionID = incomingTransactionID
        self.createdAt = createdAt
    }
}
