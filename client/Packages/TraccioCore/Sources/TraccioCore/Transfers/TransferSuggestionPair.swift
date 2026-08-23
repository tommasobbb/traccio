import Foundation

/// One suggested transfer, with both legs resolved to their
/// `TransactionResponse` — what `TransfersView` actually renders.
///
/// `TransferSuggestionResponse` alone carries no description, date, or
/// account, so a screen needs both legs' full transactions to show anything
/// meaningful (`docs/api/openapi.json`'s `TransferSuggestionResponse` schema).
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
    /// Resolve each suggestion's two legs against a pool of transactions.
    ///
    /// Pure and order-preserving: does not sort — `suggestions` is expected
    /// in the order `GET /transfers/suggestions` returns (most confident
    /// first) — it only attaches each suggestion's legs. A suggestion whose
    /// legs are not both present in `transactions` is **dropped** rather than
    /// rendered half-empty, mirroring the best-effort posture
    /// `TransactionsViewModel.categoryNames` already takes for a failed
    /// lookup.
    ///
    /// Parameters
    /// ----------
    /// suggestions:
    ///     Suggestions in display order.
    /// transactions:
    ///     The pool to resolve legs against — need not be exhaustive; only
    ///     ids matching a suggestion's legs matter.
    ///
    /// Returns
    /// -------
    /// One pair per suggestion whose legs both resolved, in input order.
    public static func pairSuggestions(
        _ suggestions: [TransferSuggestionResponse],
        transactions: [TransactionResponse]
    ) -> [TransferSuggestionPair] {
        let transactionsByID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        return suggestions.compactMap { suggestion in
            guard let outgoing = transactionsByID[suggestion.outgoingTransactionID],
                let incoming = transactionsByID[suggestion.incomingTransactionID]
            else { return nil }
            return TransferSuggestionPair(suggestion: suggestion, outgoing: outgoing, incoming: incoming)
        }
    }
}
