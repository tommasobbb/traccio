import Foundation

/// Meal-voucher spending for one currency, broken out of the headline totals
/// (ADR 0029), as returned by `GET /dashboard/summary`.
///
/// Mirrors the `MealVoucherSummaryResponse` schema in `docs/api/openapi.json`.
/// Present only when the user's meal-vouchers setting is on and there was
/// something to report — see `DashboardSummaryResponse.mealVouchers`.
public struct MealVoucherSummaryResponse: Codable, Sendable, Equatable {
    /// ISO 4217 currency code this entry is for.
    public let currency: String
    /// Total voucher spending, a non-negative magnitude, minor units.
    public let spending: Int
    /// Total voucher income (a refund onto a voucher account — rare, but not
    /// excluded), a non-negative magnitude, minor units.
    public let income: Int
    /// Count of voucher transactions contributing to this currency's totals.
    public let transactionCount: Int
    /// This currency's voucher spending partitioned by category root, same
    /// shape as `CurrencySummaryResponse.byCategory`.
    public let byCategory: [CategoryGroupSummaryResponse]

    private enum CodingKeys: String, CodingKey {
        case currency
        case spending
        case income
        case transactionCount = "transaction_count"
        case byCategory = "by_category"
    }

    public init(
        currency: String, spending: Int, income: Int, transactionCount: Int,
        byCategory: [CategoryGroupSummaryResponse] = []
    ) {
        self.currency = currency
        self.spending = spending
        self.income = income
        self.transactionCount = transactionCount
        self.byCategory = byCategory
    }
}
