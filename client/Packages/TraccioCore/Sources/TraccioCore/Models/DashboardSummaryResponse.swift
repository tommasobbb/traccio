import Foundation

/// Spending and income totals for one currency over a period, as returned by
/// `GET /dashboard/summary`.
///
/// Mirrors the `CurrencySummaryResponse` schema in `docs/api/openapi.json`.
/// Every field is required — the backend never omits or nulls one.
///
/// `spending` and `income` are always non-negative magnitudes in minor units
/// (cents); `net` is the **only signed figure** (`income - spending`), per
/// `docs/decisions/0007-dashboard-aggregation.md`. Do not assume `spending`
/// carries a negative sign — it does not.
public struct CurrencySummaryResponse: Codable, Sendable, Equatable {
    /// ISO 4217 currency code this summary is for.
    public let currency: String
    /// Total spending in the period, a non-negative magnitude, minor units.
    public let spending: Int
    /// Total income in the period, a non-negative magnitude, minor units.
    public let income: Int
    /// `income - spending`, signed, minor units — the only signed figure here.
    public let net: Int
    /// Count of transactions contributing to this currency's totals,
    /// including zero-`effective_amount` ones (transfers, reimbursements).
    public let transactionCount: Int
    /// `spending` divided by elapsed days in the period, minor units. `nil`
    /// when it cannot be derived — see the backend's
    /// `domain/dashboard.py::_average_daily_spending` for when.
    public let averageDailySpending: Int?
    /// This currency's totals partitioned by category root, each with its
    /// children rolled up. Sums to this entry's own
    /// `spending`/`income`/`transactionCount`.
    public let byCategory: [CategoryGroupSummaryResponse]
    /// This currency's totals partitioned by time bucket, gap-filled across
    /// the requested period when both `start` and `end` were sent. Unlike
    /// `byCategory`, this does **not** always sum back to this entry's own
    /// totals — a transaction with neither a booked nor a value date has
    /// nowhere to bucket, per `docs/decisions/0007-dashboard-aggregation.md`.
    public let byBucket: [BucketSummaryResponse]
    /// This currency's totals partitioned by account. Sums to this entry's
    /// own totals.
    public let byAccount: [AccountSummaryResponse]
    /// The comparison period's totals and the delta, or `nil` when no
    /// comparison was requested.
    public let comparison: ComparisonSummaryResponse?

    private enum CodingKeys: String, CodingKey {
        case currency
        case spending
        case income
        case net
        case transactionCount = "transaction_count"
        case averageDailySpending = "average_daily_spending"
        case byCategory = "by_category"
        case byBucket = "by_bucket"
        case byAccount = "by_account"
        case comparison
    }

    public init(
        currency: String, spending: Int, income: Int, net: Int, transactionCount: Int,
        averageDailySpending: Int? = nil, byCategory: [CategoryGroupSummaryResponse] = [],
        byBucket: [BucketSummaryResponse] = [], byAccount: [AccountSummaryResponse] = [],
        comparison: ComparisonSummaryResponse? = nil
    ) {
        self.currency = currency
        self.spending = spending
        self.income = income
        self.net = net
        self.transactionCount = transactionCount
        self.averageDailySpending = averageDailySpending
        self.byCategory = byCategory
        self.byBucket = byBucket
        self.byAccount = byAccount
        self.comparison = comparison
    }
}

/// Envelope returned by `GET /dashboard/summary`.
///
/// Mirrors the `DashboardSummaryResponse` schema in `docs/api/openapi.json`.
/// Traccio never converts between currencies (no FX, ADR 0007): each entry
/// in `currencies` stands alone and the entries must never be summed
/// together to produce a single figure.
public struct DashboardSummaryResponse: Codable, Sendable, Equatable {
    /// One summary per currency with transactions in the period, sorted by
    /// currency code. Empty when the period has no transactions at all.
    public let currencies: [CurrencySummaryResponse]

    public init(currencies: [CurrencySummaryResponse]) {
        self.currencies = currencies
    }
}

extension Array where Element == CurrencySummaryResponse {
    /// Pick the summary to feature as the dashboard's primary figure.
    ///
    /// This is a presentation choice, not a financial derivation: the backend
    /// does not designate a primary currency, and Traccio never converts
    /// between currencies, so there is no "correct" total to compute here —
    /// only a rule for which single summary a screen with one hero figure
    /// should show up front.
    ///
    /// Picks the entry with the most transactions; ties break on the lower
    /// currency code so the choice is deterministic.
    ///
    /// - Returns: The chosen summary, or `nil` if the array is empty.
    public func primary() -> CurrencySummaryResponse? {
        self.max { lhs, rhs in
            if lhs.transactionCount != rhs.transactionCount {
                return lhs.transactionCount < rhs.transactionCount
            }
            // Reverse comparison on currency: max() picks the "largest", and
            // we want the lower code to win a tie.
            return lhs.currency > rhs.currency
        }
    }
}
