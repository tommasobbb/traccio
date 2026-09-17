import Foundation

/// The health endpoint — one slice of `APIClientProtocol`.
public protocol HealthAPI: Sendable {
    func health() async throws -> HealthResponse
}

// Health endpoint — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient: HealthAPI {
    /// Liveness probe; a cheap smoke test of the transport and base URL.
    ///
    /// Returns
    /// -------
    /// The decoded `GET /health` payload.
    public func health() async throws -> HealthResponse {
        try await get("health")
    }
}
