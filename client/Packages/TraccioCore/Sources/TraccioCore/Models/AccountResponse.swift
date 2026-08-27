import Foundation

/// One account as returned by `GET /accounts`.
///
/// Mirrors the `AccountResponse` schema in `docs/api/openapi.json` — a
/// deliberately narrow projection: `user_id` (implied by the caller) and
/// `identification_hash` (an internal matching detail) are omitted by the
/// backend and so are absent here too.
///
/// `CodingKeys` map the backend's snake_case wire names to Swift camelCase, so
/// the type decodes with a plain decoder without relying on a global key
/// strategy. A backend field rename therefore surfaces as a decode-test
/// failure rather than a silent `nil`.
public struct AccountResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable account identifier.
    public let id: UUID
    /// Connection currently exposing this account, or `nil` for a manual
    /// account — one the user created with no bank behind it (ADR 0020).
    public let connectionID: UUID?
    /// `current`, `savings`, `card`, `wallet`, or `cash`.
    public let kind: AccountKind
    /// The account's ISO 4217 currency.
    public let currency: String
    /// Provider-supplied display name (overwritten on every sync).
    public let name: String?
    /// User-chosen display name (ADR 0017), or `nil` if unset.
    public let alias: String?
    /// The one name the client should actually show — `alias` if set, else
    /// `name`, else `nil` — resolved once by the backend so the client does
    /// not reimplement the fallback.
    public let displayName: String?
    /// User-chosen colour, or `nil` if unset.
    public let color: PaletteColor?
    /// User-chosen icon, or `nil` if unset.
    public let icon: AccountIcon?
    /// When the account was first recorded.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case connectionID = "connection_id"
        case kind
        case currency
        case name
        case alias
        case displayName = "display_name"
        case color
        case icon
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        connectionID: UUID?,
        kind: AccountKind,
        currency: String,
        name: String?,
        alias: String?,
        displayName: String?,
        color: PaletteColor?,
        icon: AccountIcon?,
        createdAt: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.kind = kind
        self.currency = currency
        self.name = name
        self.alias = alias
        self.displayName = displayName
        self.color = color
        self.icon = icon
        self.createdAt = createdAt
    }
}
