import Foundation

/// Spending and income totals for one time bucket, within one currency, as
/// returned by `GET /dashboard/summary`.
///
/// Mirrors the `BucketSummaryResponse` schema in `docs/api/openapi.json`.
/// Replaces the pre-2026-08-26 `DaySummaryResponse`/`by_day`: a bucket now
/// carries its own `end` (exclusive), and the series is gap-filled by the
/// backend across the whole requested period when both bounds are known
/// (`docs/decisions/0007-dashboard-aggregation.md`'s third revision) — the
/// client no longer walks a calendar to invent zero bars.
public struct BucketSummaryResponse: Codable, Sendable, Equatable {
    /// The bucket's start, a local calendar date (the request's `tz`).
    public let start: CalendarDate
    /// The bucket's exclusive end.
    public let end: CalendarDate
    /// Total spending in this bucket, a non-negative magnitude, minor units.
    public let spending: Int
    /// Total income in this bucket, a non-negative magnitude, minor units.
    public let income: Int
    /// Count of transactions in this bucket, including zero-`effective_amount`
    /// ones (transfers, reimbursements).
    public let transactionCount: Int

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case spending
        case income
        case transactionCount = "transaction_count"
    }

    public init(start: CalendarDate, end: CalendarDate, spending: Int, income: Int, transactionCount: Int) {
        self.start = start
        self.end = end
        self.spending = spending
        self.income = income
        self.transactionCount = transactionCount
    }
}
