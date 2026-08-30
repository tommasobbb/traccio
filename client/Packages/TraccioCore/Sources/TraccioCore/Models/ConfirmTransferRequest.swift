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
    /// Which pairing to confirm. `.twoSided` — `outgoing` negative, `incoming`
    /// positive, both legs become `role == .transfer`. `.fundedPayment` — both
    /// legs outflows, only `outgoing` (the funding leg) becomes
    /// `role == .funding`.
    public let kind: TransferKind
    /// Two-sided: the negative leg. Funded payment: the funding leg. Must
    /// belong to the caller.
    public let outgoingTransactionID: UUID
    /// Two-sided: the positive leg. Funded payment: the funded leg. Must
    /// belong to the caller.
    public let incomingTransactionID: UUID

    private enum CodingKeys: String, CodingKey {
        case kind
        case outgoingTransactionID = "outgoing_transaction_id"
        case incomingTransactionID = "incoming_transaction_id"
    }

    public init(
        kind: TransferKind = .twoSided,
        outgoingTransactionID: UUID,
        incomingTransactionID: UUID
    ) {
        self.kind = kind
        self.outgoingTransactionID = outgoingTransactionID
        self.incomingTransactionID = incomingTransactionID
    }
}
