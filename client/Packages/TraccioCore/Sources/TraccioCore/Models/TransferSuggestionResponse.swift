import Foundation

/// One suggested transfer pair, as returned by `GET /transfers/suggestions`.
///
/// Mirrors the `TransferSuggestionResponse` schema in
/// `docs/api/openapi.json`. Detection only *suggests* — nothing is written
/// until the user confirms or rejects it (see `docs/architecture.md`). Both
/// legs are embedded as their full `TransactionResponse` (`outgoing` /
/// `incoming`), the same projection `GET /transactions` returns, so a screen
/// renders a suggestion without a follow-up request per leg.
public struct TransferSuggestionResponse: Codable, Sendable, Equatable {
    /// Which pairing this suggests — `.twoSided` (opposite-sign pair) or
    /// `.fundedPayment` (two outflows, `incomingTransactionID` on a wallet is
    /// the real purchase).
    public let kind: TransferKind
    /// Two-sided: the negative leg. Funded payment: the funding leg.
    public let outgoingTransactionID: UUID
    /// Two-sided: the positive leg. Funded payment: the funded (wallet) leg.
    public let incomingTransactionID: UUID
    /// ISO 4217 code shared by both legs.
    public let currency: String
    /// The outgoing leg's amount in minor units (negative for both kinds).
    public let outgoingAmount: Int
    /// The incoming leg's amount in minor units — positive for a two-sided
    /// transfer, negative for a funded payment.
    public let incomingAmount: Int
    /// Absolute difference between the legs' magnitudes (`>= 0`); a small
    /// non-zero value is a fee or rounding.
    public let amountDelta: Int
    /// Whole days between the legs' effective dates (`>= 0`).
    public let dayGap: Int
    /// The full outgoing leg — two-sided: the negative leg; funded payment:
    /// the funding leg.
    public let outgoing: TransactionResponse
    /// The full incoming leg — two-sided: the positive leg; funded payment:
    /// the funded (wallet) leg.
    public let incoming: TransactionResponse

    private enum CodingKeys: String, CodingKey {
        case kind
        case outgoingTransactionID = "outgoing_transaction_id"
        case incomingTransactionID = "incoming_transaction_id"
        case currency
        case outgoingAmount = "outgoing_amount"
        case incomingAmount = "incoming_amount"
        case amountDelta = "amount_delta"
        case dayGap = "day_gap"
        case outgoing
        case incoming
    }

    public init(
        kind: TransferKind,
        outgoingTransactionID: UUID,
        incomingTransactionID: UUID,
        currency: String,
        outgoingAmount: Int,
        incomingAmount: Int,
        amountDelta: Int,
        dayGap: Int,
        outgoing: TransactionResponse,
        incoming: TransactionResponse
    ) {
        self.kind = kind
        self.outgoingTransactionID = outgoingTransactionID
        self.incomingTransactionID = incomingTransactionID
        self.currency = currency
        self.outgoingAmount = outgoingAmount
        self.incomingAmount = incomingAmount
        self.amountDelta = amountDelta
        self.dayGap = dayGap
        self.outgoing = outgoing
        self.incoming = incoming
    }
}
