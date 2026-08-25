import Foundation

/// One category as returned by `GET /categories`.
///
/// Mirrors the `CategoryResponse` schema in `docs/api/openapi.json`. Used to
/// resolve a transaction's `effective_category_id` to a display name — the
/// client never invents category names of its own.
///
/// Since ADR 0018, categories nest in a strict two-level hierarchy: `parentID`
/// is `nil` for a root, or names the root a child nests under. `GET
/// /categories` returns a **flat** list — not nested — ordered root, then its
/// own children, then the next root (see
/// `traccio.db.repositories.list_categories`); `TraccioCore.categoryTree(_:)`
/// is the pure function that regroups it for rendering.
public struct CategoryResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable category identifier.
    public let id: UUID
    /// User-facing name, unique per user on the backend.
    public let name: String
    /// The root this category nests under, or `nil` if it is itself a root.
    public let parentID: UUID?
    /// The category's colour (ADR 0017). Always set — the backend resolves
    /// one on every creation path.
    public let color: PaletteColor
    /// The category's icon, or `nil` if unset.
    public let icon: CategoryIcon?
    /// When the category was created.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parent_id"
        case color
        case icon
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        name: String,
        parentID: UUID?,
        color: PaletteColor,
        icon: CategoryIcon?,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.color = color
        self.icon = icon
        self.createdAt = createdAt
    }
}
