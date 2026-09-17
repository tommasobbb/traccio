import Foundation
import TraccioCore

/// `DashboardAPI` stub, mirroring `APIClient+Dashboard.swift`.
extension FakeAPIClient {
    func setDashboardSummaryResult(_ summary: DashboardSummaryResponse) {
        dashboardSummaryToReturn = summary
    }

    func setDashboardSummaryError(_ error: Error) {
        dashboardSummaryError = error
    }

    func dashboardSummary(
        start: Date?, end: Date?, granularity: BucketGranularity, tz: String?,
        compareStart: Date?, compareEnd: Date?
    ) async throws -> DashboardSummaryResponse {
        receivedDashboardSummaryRequests.append((start, end, granularity, tz, compareStart, compareEnd))
        if let dashboardSummaryError { throw dashboardSummaryError }
        return dashboardSummaryToReturn
    }
}
