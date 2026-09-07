import Foundation

/// Cross-advance roll-ups carried alongside the advance list.
///
/// Mirrors the `AdvancesSummaryResponse` schema in `docs/api/openapi.json`.
/// Computed server-side over *every* advance regardless of any `status`
/// filter on the list, so these totals do not move when the client narrows
/// the visible rows (ADR 0026).
public struct AdvancesSummaryResponse: Codable, Sendable, Equatable {
    /// One entry per person, most owed first.
    public let byPerson: [PersonSummaryResponse]
    /// One entry per currency, ordered by currency code.
    public let totals: [ReceivableTotalResponse]

    private enum CodingKeys: String, CodingKey {
        case byPerson = "by_person"
        case totals
    }

    public init(byPerson: [PersonSummaryResponse], totals: [ReceivableTotalResponse]) {
        self.byPerson = byPerson
        self.totals = totals
    }
}
