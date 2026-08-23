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

    /// Summarize real spending and income over a period, per currency.
    ///
    /// Mirrors `GET /dashboard/summary` (ADR 0007). Both bounds are optional;
    /// omitting one leaves that side of the period open-ended. When supplied,
    /// `start` is inclusive and `end` is exclusive — a half-open interval, so
    /// the caller must pass the first instant of the day *after* the last day
    /// to include, not that day's midnight.
    ///
    /// Parameters
    /// ----------
    /// start:
    ///     Inclusive lower bound, or `nil` for open-ended.
    /// end:
    ///     Exclusive upper bound, or `nil` for open-ended.
    ///
    /// Returns
    /// -------
    /// The decoded summary: one entry per currency with transactions in the
    /// period, never combined across currencies.
    public func dashboardSummary(
        start: Date? = nil,
        end: Date? = nil
    ) async throws -> DashboardSummaryResponse {
        var query: [URLQueryItem] = []
        if let start {
            query.append(URLQueryItem(name: "start", value: TraccioCore.iso8601String(from: start)))
        }
        if let end {
            query.append(URLQueryItem(name: "end", value: TraccioCore.iso8601String(from: end)))
        }
        return try await get("dashboard/summary", query: query)
    }

    /// Perform a `GET` for `path` relative to `baseURL` and decode the body.
    ///
    /// Wraps every failure in an `APIError` so no framework error — which may
    /// carry a response body — propagates unchanged.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// query:
    ///     Query items to append; an empty array (the default) produces a URL
    ///     with no `?` at all, matching the two-argument call sites exactly.
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true
        ) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

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
