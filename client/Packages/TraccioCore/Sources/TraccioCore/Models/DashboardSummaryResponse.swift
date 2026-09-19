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
/// The `currencies` entries each stand alone and must never be summed
/// together by the client. A pre-summed total across all of them, converted
/// into one base currency, is available on `converted` — but only when the
/// backend has FX enabled (`TRACCIO_FX_ENABLED`, ADR 0021) and every
/// currency could be converted; it is additive and never a replacement for
/// the per-currency breakdown.
public struct DashboardSummaryResponse: Codable, Sendable, Equatable {
    /// One summary per currency with transactions in the period, sorted by
    /// currency code. Empty when the period has no transactions at all.
    public let currencies: [CurrencySummaryResponse]
    /// The opt-in combined total in the base currency (ADR 0021), or `nil`
    /// when the feature is off, the period is empty, or a rate was missing.
    public let converted: ConvertedSummaryResponse?
    /// When FX is enabled but `converted` is still `nil`, a stable
    /// value-free reason (`"rates_unavailable"` / `"missing_rate"`). `nil`
    /// when the feature is off or conversion succeeded.
    public let conversionUnavailable: String?
    /// Meal-voucher spending, broken out of `currencies`/`converted`
    /// (ADR 0029). Empty when the user's meal-vouchers setting is off, they
    /// have no voucher-kind account, or nothing was spent from one this
    /// period. Never FX-converted.
    public let mealVouchers: [MealVoucherSummaryResponse]

    private enum CodingKeys: String, CodingKey {
        case currencies
        case converted
        case conversionUnavailable = "conversion_unavailable"
        case mealVouchers = "meal_vouchers"
    }

    public init(
        currencies: [CurrencySummaryResponse],
        converted: ConvertedSummaryResponse? = nil,
        conversionUnavailable: String? = nil,
        mealVouchers: [MealVoucherSummaryResponse] = []
    ) {
        self.currencies = currencies
        self.converted = converted
        self.conversionUnavailable = conversionUnavailable
        self.mealVouchers = mealVouchers
    }

    /// Hand-written so `meal_vouchers` tolerates a missing key — every other
    /// field stays required, same posture as `CurrencySummaryResponse`.
    /// `meal_vouchers` is newer than the rest of this envelope; decoding it
    /// with a fallback to `[]` means an existing fixture or an older cached
    /// response (`docs/engineering.md`'s local read cache) still decodes rather
    /// than failing outright, exactly as if the setting were off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currencies = try container.decode([CurrencySummaryResponse].self, forKey: .currencies)
        converted = try container.decodeIfPresent(ConvertedSummaryResponse.self, forKey: .converted)
        conversionUnavailable = try container.decodeIfPresent(
            String.self, forKey: .conversionUnavailable
        )
        mealVouchers =
            try container.decodeIfPresent([MealVoucherSummaryResponse].self, forKey: .mealVouchers)
            ?? []
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
