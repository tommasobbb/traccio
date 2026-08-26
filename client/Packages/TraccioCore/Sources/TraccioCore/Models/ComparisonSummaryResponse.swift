import Foundation

/// The comparison period's own totals and the delta from them, as returned by
/// `GET /dashboard/summary` when `compare_start`/`compare_end` were both
/// supplied.
///
/// Mirrors the `ComparisonSummaryResponse` schema in `docs/api/openapi.json`
/// — new in `docs/decisions/0007-dashboard-aggregation.md`'s third revision.
/// The client names *which* period to compare against (there is no
/// `compare=true` boolean): "same length, shifted back" is not well-defined
/// across a calendar, so the client's own `MonthPeriod.previous()` decides.
public struct ComparisonSummaryResponse: Codable, Sendable, Equatable {
    /// The comparison period's own total spending, minor units, a
    /// non-negative magnitude.
    public let spending: Int
    /// The comparison period's own total income, minor units, a non-negative
    /// magnitude.
    public let income: Int
    /// The comparison period's own net (`income - spending`), signed, minor
    /// units.
    public let net: Int
    /// Current period's spending minus the comparison period's, signed,
    /// minor units — positive means the current period spent more.
    public let spendingDelta: Int
    /// `spendingDelta` as a fraction of the comparison period's spending, or
    /// `nil` when that spending was zero (never `.infinity`). The one
    /// floating-point field in this model: a ratio, not money.
    public let spendingDeltaPct: Double?

    private enum CodingKeys: String, CodingKey {
        case spending
        case income
        case net
        case spendingDelta = "spending_delta"
        case spendingDeltaPct = "spending_delta_pct"
    }

    public init(spending: Int, income: Int, net: Int, spendingDelta: Int, spendingDeltaPct: Double?) {
        self.spending = spending
        self.income = income
        self.net = net
        self.spendingDelta = spendingDelta
        self.spendingDeltaPct = spendingDeltaPct
    }
}
