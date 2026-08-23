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
    /// Connection currently exposing this account.
    public let connectionID: UUID
    /// `current`, `savings`, or `card`.
    public let kind: AccountKind
    /// The account's ISO 4217 currency.
    public let currency: String
    /// Optional display name.
    public let name: String?
    /// When the account was first recorded.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case connectionID = "connection_id"
        case kind
        case currency
        case name
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        connectionID: UUID,
        kind: AccountKind,
        currency: String,
        name: String?,
        createdAt: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.kind = kind
        self.currency = currency
        self.name = name
        self.createdAt = createdAt
    }
}
