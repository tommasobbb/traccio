import Foundation

/// Bank-connection endpoints — one slice of `APIClientProtocol`.
public protocol ConnectionsAPI: Sendable {
    func connections() async throws -> [ConnectionResponse]
    func institutions(country: String) async throws -> [InstitutionResponse]
    func startConnection(
        institution: String, country: String, logo: String?
    ) async throws -> StartConnectionResponse
    func syncConnection(connectionID: UUID) async throws -> SyncResponse
    func reauthorizeConnection(connectionID: UUID) async throws -> StartConnectionResponse
    func backfillConnectionLogos() async throws -> BackfillLogosResponse
}

// Bank-connection endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient: ConnectionsAPI {
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

    /// List the banks the caller can start a new connection with.
    ///
    /// Parameters
    /// ----------
    /// country:
    ///     ISO 3166-1 alpha-2 country to list institutions for.
    ///
    /// Returns
    /// -------
    /// The institutions offered in `country`, in the provider's own order.
    public func institutions(country: String) async throws -> [InstitutionResponse] {
        let envelope: InstitutionsResponse = try await get(
            "connections/institutions", query: [URLQueryItem(name: "country", value: country)]
        )
        return envelope.institutions
    }

    /// Start a new bank connection.
    ///
    /// Mirrors `POST /connections`: begins a fresh SCA round with the given
    /// institution rather than re-arming an existing connection.
    ///
    /// Parameters
    /// ----------
    /// institution:
    ///     The provider-scoped institution identifier, typically picked from
    ///     `institutions(country:)`.
    /// country:
    ///     ISO 3166-1 alpha-2 country the institution was offered in.
    /// logo:
    ///     The picked institution's `logo` URL, passed straight through so the
    ///     backend stores it on the connection for the Conti screen. `nil`
    ///     when the picker had none.
    ///
    /// Returns
    /// -------
    /// Where to send the user — open `authorizationURL` in the system
    /// browser, never an in-app `WebView`.
    public func startConnection(
        institution: String, country: String, logo: String? = nil
    ) async throws -> StartConnectionResponse {
        try await post(
            "connections",
            body: StartConnectionRequest(institution: institution, country: country, logo: logo)
        )
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

    /// Backfill missing institution logos on the caller's connections.
    ///
    /// Mirrors `POST /connections/backfill-logos`. Idempotent — a connection
    /// that already has a logo, has no stored country, or matches no provider
    /// institution is left untouched.
    ///
    /// Returns
    /// -------
    /// How many connections gained a logo.
    public func backfillConnectionLogos() async throws -> BackfillLogosResponse {
        try await post("connections/backfill-logos")
    }
}
