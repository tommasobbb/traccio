/// Payload returned by `GET /health`.
///
/// Mirrors the `HealthResponse` schema in `docs/api/openapi.json`.
public struct HealthResponse: Codable, Sendable {
    /// Liveness marker; `"ok"` when the app is serving.
    public let status: String
    /// The running application version.
    public let version: String

    public init(status: String, version: String) {
        self.status = status
        self.version = version
    }
}
