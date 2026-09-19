import Foundation

/// A started (or restarted) bank authorization: where to send the user.
///
/// Mirrors the `StartConnectionResponse` schema in `docs/api/openapi.json`,
/// returned by both `POST /connections` and
/// `POST /connections/{id}/reauthorize`. `authorizationURL` must be opened in
/// the system browser, never an in-app `WebView` — bank SCA apps often fail
/// to open from one (`docs/engineering.md`, `docs/openbanking.md`).
public struct StartConnectionResponse: Codable, Sendable, Equatable {
    /// The connection this authorization is for — a fresh one for
    /// `POST /connections`, the same one re-armed for `reauthorize`.
    public let connectionID: UUID
    /// The bank authorization URL to open in the system browser.
    public let authorizationURL: String

    private enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case authorizationURL = "authorization_url"
    }

    public init(connectionID: UUID, authorizationURL: String) {
        self.connectionID = connectionID
        self.authorizationURL = authorizationURL
    }
}
