import Foundation
import TraccioCore

/// `HealthAPI` stub, mirroring `APIClient+Health.swift`.
extension FakeAPIClient {
    func setHealthError(_ error: Error) {
        healthError = error
    }

    func health() async throws -> HealthResponse {
        if let healthError { throw healthError }
        return healthToReturn
    }
}
