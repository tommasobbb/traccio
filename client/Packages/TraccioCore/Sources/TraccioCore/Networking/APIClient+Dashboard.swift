import Foundation

/// The dashboard endpoint — one slice of `APIClientProtocol`.
public protocol DashboardAPI: Sendable {
    func dashboardSummary(
        start: Date?, end: Date?, granularity: BucketGranularity, tz: String?,
        compareStart: Date?, compareEnd: Date?
    ) async throws -> DashboardSummaryResponse
}

// Dashboard endpoint — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient: DashboardAPI {
    /// Summarize real spending and income over a period, per currency.
    ///
    /// Mirrors `GET /dashboard/summary` (`docs/decisions/
    /// 0007-dashboard-aggregation.md`). Both bounds are optional; omitting one
    /// leaves that side of the period open-ended. When supplied, `start` is
    /// inclusive and `end` is exclusive — a half-open interval, so the caller
    /// must pass the first instant of the day *after* the last day to
    /// include, not that day's midnight. `byBucket` is gap-filled across the
    /// whole period only when both bounds are given.
    ///
    /// `compareStart`/`compareEnd` must both be supplied or both omitted —
    /// the caller names *which* period to compare against (typically via its
    /// own `previous()`), not a boolean; the backend rejects exactly one
    /// being set with `422 incomplete_comparison_period`.
    ///
    /// Parameters
    /// ----------
    /// start:
    ///     Inclusive lower bound, or `nil` for open-ended.
    /// end:
    ///     Exclusive upper bound, or `nil` for open-ended.
    /// granularity:
    ///     How `byBucket` groups time. Defaults to one bucket per day.
    /// tz:
    ///     IANA timezone name bucketing happens in, or `nil` to let the
    ///     backend default to UTC.
    /// compareStart:
    ///     Inclusive lower bound of the comparison period, or `nil` for none.
    /// compareEnd:
    ///     Exclusive upper bound of the comparison period, or `nil` for none.
    ///
    /// Returns
    /// -------
    /// The decoded summary: one entry per currency with transactions in the
    /// period, never combined across currencies.
    public func dashboardSummary(
        start: Date? = nil,
        end: Date? = nil,
        granularity: BucketGranularity = .day,
        tz: String? = nil,
        compareStart: Date? = nil,
        compareEnd: Date? = nil
    ) async throws -> DashboardSummaryResponse {
        var query: [URLQueryItem] = []
        if let start {
            query.append(URLQueryItem(name: "start", value: TraccioCore.iso8601String(from: start)))
        }
        if let end {
            query.append(URLQueryItem(name: "end", value: TraccioCore.iso8601String(from: end)))
        }
        if granularity != .day {
            query.append(URLQueryItem(name: "granularity", value: granularity.rawValue))
        }
        if let tz {
            query.append(URLQueryItem(name: "tz", value: tz))
        }
        if let compareStart {
            query.append(
                URLQueryItem(name: "compare_start", value: TraccioCore.iso8601String(from: compareStart))
            )
        }
        if let compareEnd {
            query.append(
                URLQueryItem(name: "compare_end", value: TraccioCore.iso8601String(from: compareEnd))
            )
        }
        return try await get("dashboard/summary", query: query)
    }
}
