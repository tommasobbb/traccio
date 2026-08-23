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

    /// Fetch one transaction by id.
    ///
    /// Mirrors `GET /transactions/{id}`. Exists so a caller can re-fetch a
    /// single row's server-derived `effectiveAmount`/`effectiveCategoryID`
    /// after a write (e.g. confirming a category) without re-paginating the
    /// whole list — the backend still owns every derived value
    /// (`client/CLAUDE.md`).
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded transaction.
    public func transaction(id: UUID) async throws -> TransactionResponse {
        try await get("transactions/\(id.uuidString)")
    }

    /// Confirm a category on a transaction — the explicit user action.
    ///
    /// Mirrors `POST /transactions/{id}/category`, which returns `204 No
    /// Content` on success: the caller re-fetches via `transaction(id:)` to
    /// observe the new `effectiveCategoryID` rather than this method
    /// returning or inferring one.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to categorize.
    /// categoryID:
    ///     The category to confirm; must belong to the caller.
    public func confirmCategory(transactionID: UUID, categoryID: UUID) async throws {
        try await post(
            "transactions/\(transactionID.uuidString)/category",
            body: ConfirmCategoryRequest(categoryID: categoryID)
        )
    }

    /// Clear a transaction's confirmed category, falling back to any
    /// suggestion.
    ///
    /// Mirrors `POST`'s sibling `DELETE /transactions/{id}/category`, also
    /// `204 No Content`. Idempotent on the backend: clearing an already-clear
    /// transaction still succeeds.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to clear.
    public func clearCategory(transactionID: UUID) async throws {
        try await delete("transactions/\(transactionID.uuidString)/category")
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

    /// Seed the caller's default category set.
    ///
    /// Mirrors `POST /categories/defaults` — the unblock for a category
    /// picker on a fresh database with no categories yet. Idempotent on the
    /// backend for categories already present.
    ///
    /// Returns
    /// -------
    /// The full set of categories after seeding.
    public func seedDefaultCategories() async throws -> [CategoryResponse] {
        let envelope: CategoriesResponse = try await post("categories/defaults")
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

    /// Suggest transfers among the caller's transactions.
    ///
    /// Mirrors `GET /transfers/suggestions`. Detection only *suggests* — see
    /// `confirmTransfer(outgoingID:incomingID:)` for the write that acts on
    /// one.
    ///
    /// Returns
    /// -------
    /// The suggested transfers, most confident first (empty if none).
    public func transferSuggestions() async throws -> [TransferSuggestionResponse] {
        let envelope: TransferSuggestionsResponse = try await get("transfers/suggestions")
        return envelope.suggestions
    }

    /// Fetch the caller's confirmed transfers, oldest first.
    ///
    /// Mirrors `GET /transfers`.
    ///
    /// Returns
    /// -------
    /// The decoded transfers.
    public func transfers() async throws -> [TransferResponse] {
        let envelope: TransfersResponse = try await get("transfers")
        return envelope.transfers
    }

    /// Confirm two transactions as a transfer — the explicit user action that
    /// turns a suggestion into a persisted link.
    ///
    /// Mirrors `POST /transfers/confirm`, which sets both legs' `role` to
    /// `transfer` and returns the created transfer. Both legs'
    /// `effectiveAmount` becomes zero as a result; the caller re-fetches them
    /// via `transaction(id:)` to observe that, same discipline as
    /// `confirmCategory(transactionID:categoryID:)`.
    ///
    /// Parameters
    /// ----------
    /// outgoingID:
    ///     The negative leg (money left an account).
    /// incomingID:
    ///     The positive leg (money arrived in another account).
    ///
    /// Returns
    /// -------
    /// The created transfer.
    public func confirmTransfer(outgoingID: UUID, incomingID: UUID) async throws -> TransferResponse {
        try await post(
            "transfers/confirm",
            body: ConfirmTransferRequest(
                outgoingTransactionID: outgoingID, incomingTransactionID: incomingID
            )
        )
    }

    /// Reject a suggested pair so it is not suggested again.
    ///
    /// Mirrors `POST /transfers/reject`, `204 No Content` on success.
    /// Idempotent on the backend: rejecting the same pair twice changes
    /// nothing.
    ///
    /// Parameters
    /// ----------
    /// outgoingID:
    ///     One leg of the rejected pair (the suggestion's outgoing leg).
    /// incomingID:
    ///     The other leg of the rejected pair (the suggestion's incoming leg).
    public func rejectTransfer(outgoingID: UUID, incomingID: UUID) async throws {
        try await post(
            "transfers/reject",
            body: RejectTransferRequest(
                outgoingTransactionID: outgoingID, incomingTransactionID: incomingID
            )
        )
    }

    /// Delete a confirmed transfer and revert both legs to `personal`.
    ///
    /// Mirrors `DELETE /transfers/{id}`, `204 No Content` on success. The
    /// caller re-fetches both legs via `transaction(id:)` to observe their
    /// restored `effectiveAmount`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transfer to delete.
    public func deleteTransfer(id: UUID) async throws {
        try await delete("transfers/\(id.uuidString)")
    }

    /// Perform a request against `path` relative to `baseURL` and return the
    /// raw response body.
    ///
    /// The shared transport underneath every other private helper: URL
    /// assembly, the `URLSession` call, and the `HTTPURLResponse`/status
    /// check all happen exactly once here. Wraps every failure in an
    /// `APIError` so no framework error — which may carry a response body —
    /// propagates unchanged.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// method:
    ///     HTTP method to use.
    /// query:
    ///     Query items to append; an empty array (the default) produces a URL
    ///     with no `?` at all.
    /// body:
    ///     Raw request body, already encoded, or `nil` for none.
    ///
    /// Returns
    /// -------
    /// The raw, undecoded response body (empty for a `204 No Content`).
    private func send(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
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

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

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
        return data
    }

    /// Perform a `GET` for `path` relative to `baseURL` and decode the body.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// query:
    ///     Query items to append; an empty array (the default) produces a URL
    ///     with no `?` at all, matching the two-argument call sites exactly.
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, method: "GET", query: query)
        do {
            return try TraccioCore.jsonDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// Perform a `POST` for `path` relative to `baseURL` and decode the body.
    ///
    /// No request body: for a write that takes one, see the `Encodable`
    /// overload below.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    private func post<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(path, method: "POST")
        do {
            return try TraccioCore.jsonDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// Perform a `POST` for `path` with an encoded body, expecting no
    /// response body (`204 No Content`).
    ///
    /// Both category-confirmation endpoints answer this way; a variant that
    /// also decodes a `200` body is a separate addition for whenever a future
    /// write needs one.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// body:
    ///     The request body to encode as JSON.
    private func post<Body: Encodable>(_ path: String, body: Body) async throws {
        let encoded: Data
        do {
            encoded = try TraccioCore.jsonEncoder().encode(body)
        } catch {
            throw APIError.encoding(underlying: error)
        }
        _ = try await send(path, method: "POST", body: encoded)
    }

    /// Perform a `POST` for `path` with an encoded body, decoding the
    /// response.
    ///
    /// The counterpart to the two overloads above, for a write that both
    /// sends and receives a body — `confirmTransfer(outgoingID:incomingID:)`
    /// is the first caller (`POST /transfers/confirm` answers `201` with the
    /// created transfer).
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// body:
    ///     The request body to encode as JSON.
    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let encoded: Data
        do {
            encoded = try TraccioCore.jsonEncoder().encode(body)
        } catch {
            throw APIError.encoding(underlying: error)
        }
        let data = try await send(path, method: "POST", body: encoded)
        do {
            return try TraccioCore.jsonDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// Perform a `DELETE` for `path`, expecting no response body (`204 No
    /// Content`).
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    private func delete(_ path: String) async throws {
        _ = try await send(path, method: "DELETE")
    }
}
