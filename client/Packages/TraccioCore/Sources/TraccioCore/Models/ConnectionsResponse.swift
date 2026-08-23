/// Envelope for the connection list returned by `GET /connections`.
///
/// Mirrors the `ConnectionsResponse` schema in `docs/api/openapi.json`. A
/// wrapper object rather than a bare array leaves room for pagination
/// metadata later without breaking decoding — same reasoning as
/// `AccountsResponse`.
public struct ConnectionsResponse: Codable, Sendable {
    /// The caller's connections, oldest first.
    public let connections: [ConnectionResponse]

    public init(connections: [ConnectionResponse]) {
        self.connections = connections
    }
}
