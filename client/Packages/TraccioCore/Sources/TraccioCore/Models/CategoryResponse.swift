import Foundation

/// One category as returned by `GET /categories`.
///
/// Mirrors the `CategoryResponse` schema in `docs/api/openapi.json`. Used to
/// resolve a transaction's `effective_category_id` to a display name — the
/// client never invents category names of its own.
public struct CategoryResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable category identifier.
    public let id: UUID
    /// User-facing name, unique per user on the backend.
    public let name: String
    /// When the category was created.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
    }

    public init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
