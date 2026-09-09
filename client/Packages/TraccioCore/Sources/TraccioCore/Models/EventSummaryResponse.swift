import Foundation

/// One event's spending broken down by category, as returned by
/// `GET /events/{id}/summary` (ADR 0028).
///
/// Mirrors the `EventSummaryResponse` schema in `docs/api/openapi.json`. The
/// backend reuses the dashboard's own aggregation over the event's members,
/// so `byCategory` is the exact same shape `GET /dashboard/summary` returns
/// — the client renders it with the same `DonutChart` and
/// `CategoryBreakdownList`. An event is single-currency by construction, so
/// there is one figure per field; `currency` is `nil` and the totals are `0`
/// for an empty event. Every figure is server-derived; the client never sums.
public struct EventSummaryResponse: Codable, Sendable, Equatable {
    /// Total spending across the members, a positive magnitude (cents).
    public let spending: Int
    /// Total income across the members, a positive magnitude (cents).
    public let income: Int
    /// `income - spending`, signed — matches `EventResponse.total`.
    public let net: Int
    /// ISO 4217 code of the figures, or `nil` for an empty event.
    public let currency: String?
    /// The members' spending/income partitioned by category root, each with
    /// its children rolled up (ADR 0018's two levels).
    public let byCategory: [CategoryGroupSummaryResponse]

    private enum CodingKeys: String, CodingKey {
        case spending
        case income
        case net
        case currency
        case byCategory = "by_category"
    }

    public init(
        spending: Int,
        income: Int,
        net: Int,
        currency: String?,
        byCategory: [CategoryGroupSummaryResponse]
    ) {
        self.spending = spending
        self.income = income
        self.net = net
        self.currency = currency
        self.byCategory = byCategory
    }
}
