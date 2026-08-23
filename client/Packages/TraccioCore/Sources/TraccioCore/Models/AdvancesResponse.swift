/// Envelope for the advance list returned by `GET /advances`.
///
/// Mirrors the `AdvancesResponse` schema in `docs/api/openapi.json`. A
/// wrapper object rather than a bare array leaves room for pagination
/// metadata later without breaking decoding — same reasoning as
/// `AccountsResponse`.
public struct AdvancesResponse: Codable, Sendable {
    /// The user's advances, oldest first.
    public let advances: [AdvanceResponse]

    public init(advances: [AdvanceResponse]) {
        self.advances = advances
    }
}
