/// Envelope for the advance list returned by `GET /advances`.
///
/// Mirrors the `AdvancesResponse` schema in `docs/api/openapi.json`. A
/// wrapper object rather than a bare array carries the cross-advance
/// `summary` alongside the rows in one round trip — same reasoning as
/// `AccountsResponse` leaving room for metadata.
public struct AdvancesResponse: Codable, Sendable, Equatable {
    /// The user's advances, oldest first — narrowed by the `status` query
    /// parameter when one is passed.
    public let advances: [AdvanceResponse]
    /// Roll-ups over every advance, unaffected by the `status` filter.
    public let summary: AdvancesSummaryResponse

    public init(advances: [AdvanceResponse], summary: AdvancesSummaryResponse) {
        self.advances = advances
        self.summary = summary
    }
}
