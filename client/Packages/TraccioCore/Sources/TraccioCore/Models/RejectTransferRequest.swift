import Foundation

/// Body for `POST /transfers/reject`.
///
/// Mirrors the `RejectTransferRequest` schema in `docs/api/openapi.json`.
/// Field-identical to `ConfirmTransferRequest` on the wire — kept separate
/// for the same reason, see that type's doc comment.
public struct RejectTransferRequest: Encodable, Sendable {
    /// One leg of the rejected pair (the suggestion's outgoing leg).
    public let outgoingTransactionID: UUID
    /// The other leg of the rejected pair (the suggestion's incoming leg).
    public let incomingTransactionID: UUID

    private enum CodingKeys: String, CodingKey {
        case outgoingTransactionID = "outgoing_transaction_id"
        case incomingTransactionID = "incoming_transaction_id"
    }

    public init(outgoingTransactionID: UUID, incomingTransactionID: UUID) {
        self.outgoingTransactionID = outgoingTransactionID
        self.incomingTransactionID = incomingTransactionID
    }
}
