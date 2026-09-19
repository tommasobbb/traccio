import Foundation

/// A thin async client over the Traccio backend HTTP API.
///
/// This is where the client's networking lives — the app target only renders
/// what these methods return (see `docs/engineering.md`). The client has no notion
/// of *bank* tokens: it never stores or forwards a bank credential; those never
/// leave the backend. `apiToken` below is a different thing entirely — the
/// app's own shared secret for reaching its own backend (ADR 0014), sent as a
/// plain bearer header, never a bank credential.
///
/// The `URLSession` is injectable so tests can drive the client with a stub
/// transport (a `URLProtocol`) instead of hitting the network; a caller that
/// does not inject one gets `defaultSession`, which carries explicit timeouts
/// (see below) rather than `URLSessionConfiguration`'s 7-day resource default.
public struct APIClient: Sendable {
    /// Seconds a single request may stall — no bytes moving in either
    /// direction — before it fails. An idle timeout, reset whenever data
    /// arrives, so a slow-but-progressing response (a large sync) is fine;
    /// 30s of total silence is a wedged backend, not slowness.
    private static let requestTimeout: TimeInterval = 30
    /// Hard ceiling on a whole request/response including connection setup.
    /// Generous enough for the one genuinely long call (a first
    /// `POST /connections/{id}/sync` over years of history), short enough
    /// that a hung backend surfaces as an error in a couple of minutes
    /// instead of an indefinite spinner.
    private static let resourceTimeout: TimeInterval = 120

    /// The session used when a caller injects none: the default
    /// configuration plus the two timeouts above, and `waitsForConnectivity`
    /// left off so an offline request fails fast instead of parking until
    /// `resourceTimeout`. One shared instance — `URLSession` is thread-safe
    /// and reusing it is the intended usage.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Base URL the endpoints are resolved against, e.g. `http://localhost:8000`.
    let baseURL: URL
    /// Sent as `Authorization: Bearer <apiToken>` on every request when set;
    /// omitted entirely when `nil` (a backend with no `TRACCIO_API_TOKEN`
    /// configured, e.g. local `make run`).
    let apiToken: String?
    /// The session used for requests; defaults to `defaultSession`.
    let session: URLSession

    /// Create a client.
    ///
    /// Parameters
    /// ----------
    /// baseURL:
    ///     Root the endpoint paths are appended to.
    /// apiToken:
    ///     The backend's shared API token, or `nil` if unconfigured — see
    ///     the type's doc comment.
    /// session:
    ///     Transport to use; inject a stubbed session in tests. Defaults to
    ///     `defaultSession` (explicit timeouts).
    public init(baseURL: URL, apiToken: String? = nil, session: URLSession = APIClient.defaultSession) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.session = session
    }

    // MARK: - Transport

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
    func send(
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
        if let apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
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
            if http.statusCode == 401 {
                throw APIError.unauthorized
            }
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
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
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
    func post<T: Decodable>(_ path: String) async throws -> T {
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
    func post<Body: Encodable>(_ path: String, body: Body) async throws {
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
    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
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
    func delete(_ path: String) async throws {
        _ = try await send(path, method: "DELETE")
    }
}
