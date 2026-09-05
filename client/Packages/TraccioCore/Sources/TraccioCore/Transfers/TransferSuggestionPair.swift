import Foundation

/// One suggested transfer, flattened for the view: the suggestion plus its
/// two legs lifted out of it, and a stable `id` for `ForEach`.
///
/// `TransferSuggestionResponse` already embeds both legs (`outgoing` /
/// `incoming`); this type just gives `TransfersView` an `Identifiable` value
/// keyed on the leg-id pair (a suggestion carries no id of its own).
public struct TransferSuggestionPair: Identifiable, Equatable, Sendable {
    public let suggestion: TransferSuggestionResponse
    public let outgoing: TransactionResponse
    public let incoming: TransactionResponse

    /// The pair of transaction ids that identifies this suggestion —
    /// suggestions carry no id of their own on the wire.
    public var id: String {
        "\(suggestion.outgoingTransactionID.uuidString)_\(suggestion.incomingTransactionID.uuidString)"
    }

    public init(suggestion: TransferSuggestionResponse, outgoing: TransactionResponse, incoming: TransactionResponse) {
        self.suggestion = suggestion
        self.outgoing = outgoing
        self.incoming = incoming
    }
}

extension TraccioCore {
    /// Flatten each suggestion into a `TransferSuggestionPair`.
    ///
    /// Pure and order-preserving: `suggestions` is expected in the order
    /// `GET /transfers/suggestions` returns (most confident first), and the
    /// legs come straight off each `TransferSuggestionResponse` — the
    /// backend embeds them, so nothing can fail to resolve here.
    ///
    /// Parameters
    /// ----------
    /// suggestions:
    ///     Suggestions in display order.
    ///
    /// Returns
    /// -------
    /// One pair per suggestion, in input order.
    public static func pairSuggestions(
        _ suggestions: [TransferSuggestionResponse]
    ) -> [TransferSuggestionPair] {
        suggestions.map { suggestion in
            TransferSuggestionPair(
                suggestion: suggestion,
                outgoing: suggestion.outgoing,
                incoming: suggestion.incoming
            )
        }
    }
}
