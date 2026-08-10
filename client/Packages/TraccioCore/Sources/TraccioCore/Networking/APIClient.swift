import Foundation

/// A thin async client over the Traccio backend HTTP API.
///
/// This is where the client's networking lives — the app target only renders
/// what these methods return (see `client/CLAUDE.md`). The client has no notion
/// of tokens: it sends no authorization header and stores no credentials; bank
/// tokens never leave the backend.
///
/// The `URLSession` is injectable so tests can drive the client with a stub
/// transport (a `URLProtocol`) instead of hitting the network.
public struct APIClient: Sendable {
    /// Base URL the endpoints are resolved against, e.g. `http://localhost:8000`.
    private let baseURL: URL
    /// The session used for requests; defaults to `.shared`.
    private let session: URLSession

    /// Create a client.
    ///
    /// Parameters
    /// ----------
    /// baseURL:
    ///     Root the endpoint paths are appended to.
    /// session:
    ///     Transport to use; inject a stubbed session in tests. Defaults to
    ///     `URLSession.shared`.
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Fetch the caller's accounts, oldest first.
    ///
    /// Returns
    /// -------
    /// The decoded accounts from `GET /accounts`.
    public func accounts() async throws -> [AccountResponse] {
        let envelope: AccountsResponse = try await get("accounts")
        return envelope.accounts
    }

    /// Liveness probe; a cheap smoke test of the transport and base URL.
    ///
    /// Returns
    /// -------
    /// The decoded `GET /health` payload.
    public func health() async throws -> HealthResponse {
        try await get("health")
    }

    /// Perform a `GET` for `path` relative to `baseURL` and decode the body.
    ///
    /// Wraps every failure in an `APIError` so no framework error — which may
    /// carry a response body — propagates unchanged.
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw APIError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }

        do {
            return try TraccioCore.jsonDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
