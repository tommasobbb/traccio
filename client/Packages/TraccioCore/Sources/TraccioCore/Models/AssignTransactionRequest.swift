import Foundation

/// Body for `POST /events/{event_id}/transactions`.
///
/// Mirrors the `AssignTransactionRequest` schema in `docs/api/openapi.json`.
public struct AssignTransactionRequest: Encodable, Sendable {
    /// The transaction to group under the event. Must belong to the caller.
    public let transactionID: UUID

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
    }

    public init(transactionID: UUID) {
        self.transactionID = transactionID
    }
}
