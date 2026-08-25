import Foundation

/// Body for `POST /categories`.
///
/// Mirrors the `CreateCategoryRequest` schema in `docs/api/openapi.json`. A
/// separate type from `RenameCategoryRequest` despite the identical name
/// field, because the two are distinct backend schemas
/// (`api/schemas/categories.py`) that may diverge later — the same reasoning
/// as `ConfirmTransferRequest`/`RejectTransferRequest`.
///
/// No `CodingKeys`: every wire name equals the property name. The backend
/// validates length and blankness (`domain/categories.py::normalize_category_name`),
/// the parent's depth (ADR 0018), and name uniqueness; the client does not
/// re-check any of them, letting a `404`/`409`/`422` surface instead
/// (`.claude/rules/swift.md`).
public struct CreateCategoryRequest: Encodable, Sendable {
    /// The category's name, e.g. `"Alimentari"`.
    public let name: String
    /// The root this category should nest under, or `nil` to create a root.
    public let parentID: UUID?
    /// The category's colour, or `nil` to default to the parent's own colour
    /// (a child) or slate (a root).
    public let color: PaletteColor?
    /// The category's icon, or `nil` to leave it unset.
    public let icon: CategoryIcon?

    private enum CodingKeys: String, CodingKey {
        case name
        case parentID = "parent_id"
        case color
        case icon
    }

    public init(
        name: String, parentID: UUID? = nil, color: PaletteColor? = nil, icon: CategoryIcon? = nil
    ) {
        self.name = name
        self.parentID = parentID
        self.color = color
        self.icon = icon
    }
}
