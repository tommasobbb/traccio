import Foundation

/// Body for `POST /transfers/confirm`.
///
/// Mirrors the `ConfirmTransferRequest` schema in `docs/api/openapi.json`.
/// Field-identical to `RejectTransferRequest` on the wire, but kept as a
/// separate type: `client/CLAUDE.md`'s "models mirror the backend schema" is
/// what makes an independent rename on either endpoint a compile error —
/// collapsing the two into one shared type would quietly lose that for
/// whichever endpoint changes.
public struct ConfirmTransferRequest: Encodable, Sendable {
    /// The negative leg (money left an account). Must belong to the caller.
    public let outgoingTransactionID: UUID
    /// The positive leg (money arrived in another account). Must belong to
    /// the caller.
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
