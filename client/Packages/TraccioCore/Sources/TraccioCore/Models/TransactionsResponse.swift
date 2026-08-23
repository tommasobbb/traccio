/// Envelope for the transaction list returned by `GET /transactions`.
///
/// Mirrors the `TransactionsResponse` schema in `docs/api/openapi.json`. A
/// wrapper object rather than a bare array leaves room for pagination
/// metadata later without breaking decoding — same reasoning as
/// `AccountsResponse`.
public struct TransactionsResponse: Codable, Sendable {
    /// The requested page of the caller's transactions, most recent first.
    public let transactions: [TransactionResponse]

    public init(transactions: [TransactionResponse]) {
        self.transactions = transactions
    }
}
