/// Envelope for the `GET /transfers` list.
///
/// Mirrors the `TransfersResponse` schema in `docs/api/openapi.json`. A
/// wrapper object rather than a bare array leaves room for metadata later
/// without breaking decoding — same reasoning as `AccountsResponse`.
public struct TransfersResponse: Codable, Sendable {
    /// The user's confirmed transfers, oldest first.
    public let transfers: [TransferResponse]

    public init(transfers: [TransferResponse]) {
        self.transfers = transfers
    }
}
