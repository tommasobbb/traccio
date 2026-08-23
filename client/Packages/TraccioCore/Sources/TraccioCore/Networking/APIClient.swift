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

    /// Fetch a page of the caller's transactions, most recent first.
    ///
    /// Mirrors `GET /transactions` (`docs/api/openapi.json`). Ordering,
    /// pagination bounds, and the account-scoping rule all live on the
    /// backend; this method only shapes the request and decodes the result.
    ///
    /// Parameters
    /// ----------
    /// accountID:
    ///     When given, restrict to this account. `nil` returns every account.
    /// limit:
    ///     Page size; the backend validates `1...200` and defaults to `50`.
    /// offset:
    ///     Number of rows to skip, for paging past the first page.
    ///
    /// Returns
    /// -------
    /// The decoded page of transactions, most recent first.
    public func transactions(
        accountID: UUID? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [TransactionResponse] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let accountID {
            query.append(URLQueryItem(name: "account_id", value: accountID.uuidString))
        }
        let envelope: TransactionsResponse = try await get("transactions", query: query)
        return envelope.transactions
    }

    /// Fetch the caller's categories.
    ///
    /// Returns
    /// -------
    /// The decoded categories from `GET /categories`.
    public func categories() async throws -> [CategoryResponse] {
        let envelope: CategoriesResponse = try await get("categories")
        return envelope.categories
    }

    /// Fetch the caller's advances.
    ///
    /// Returns
    /// -------
    /// The decoded advances from `GET /advances`, oldest first. Each carries
    /// the server-derived `receivable`/`reimbursed`/`outstanding`/`excess` —
    /// the client never recomputes these.
    public func advances() async throws -> [AdvanceResponse] {
        let envelope: AdvancesResponse = try await get("advances")
        return envelope.advances
    }

    /// Fetch the caller's bank connections, oldest first.
    ///
    /// Returns
    /// -------
    /// The decoded connections from `GET /connections`, each carrying the
    /// server-derived `consentState` and `daysUntilExpiry` — the client
    /// renders these and never recomputes them from `expiresAt`.
    public func connections() async throws -> [ConnectionResponse] {
        let envelope: ConnectionsResponse = try await get("connections")
        return envelope.connections
    }

    /// Sync a connection's accounts and transactions with the bank.
    ///
    /// The client's first write action: a real provider call with a real
    /// rate-limit budget (`docs/openbanking.md`), so this should only be
    /// invoked on a deliberate user action (a tap), never polled.
    ///
    /// Parameters
    /// ----------
    /// connectionID:
    ///     The connection to sync.
    ///
    /// Returns
    /// -------
    /// How many accounts and transactions were discovered and persisted. The
    /// data itself is read back via `accounts()`/`transactions(...)`.
    public func syncConnection(connectionID: UUID) async throws -> SyncResponse {
        try await post("connections/\(connectionID.uuidString)/sync")
    }

    /// Re-authorize a connection whose consent has lapsed or is close to it.
    ///
    /// Mirrors `POST /connections/{id}/reauthorize`: re-arms the existing
    /// connection with a fresh SCA round rather than creating a new one.
    ///
    /// Parameters
    /// ----------
    /// connectionID:
    ///     The connection to re-authorize.
    ///
    /// Returns
    /// -------
    /// Where to send the user — open `authorizationURL` in the system
    /// browser, never an in-app `WebView`.
    public func reauthorizeConnection(connectionID: UUID) async throws -> StartConnectionResponse {
        try await post("connections/\(connectionID.uuidString)/reauthorize")
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

    /// Perform a `POST` for `path` relative to `baseURL` and decode the body.
    ///
    /// No request body: every write in this client so far (`syncConnection`,
    /// `reauthorizeConnection`) takes none. A method taking an `Encodable`
    /// body is a separate addition for the first write that needs one.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    private func post<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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
