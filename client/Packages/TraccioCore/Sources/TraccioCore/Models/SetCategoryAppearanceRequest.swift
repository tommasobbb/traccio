/// Body for `POST /categories/{id}/appearance`.
///
/// Mirrors the `SetCategoryAppearanceRequest` schema in
/// `docs/api/openapi.json`. `color` is mandatory and never `nil` — a category
/// always has one. `icon` is mandatory-but-nullable on the backend, so
/// clearing it needs an explicit JSON `null`, not an omitted key: a
/// hand-written `encode(to:)` is required for that, since Swift's synthesized
/// `Encodable` conformance uses `encodeIfPresent` for an `Optional` stored
/// property and would otherwise silently omit the key on `nil` (see
/// `RenameAccountRequest`'s doc comment for the full explanation).
public struct SetCategoryAppearanceRequest: Encodable, Sendable {
    /// The new colour.
    public let color: PaletteColor
    /// The new icon, or `nil` to clear it.
    public let icon: CategoryIcon?

    public init(color: PaletteColor, icon: CategoryIcon?) {
        self.color = color
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case icon
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color, forKey: .color)
        try container.encode(icon, forKey: .icon)
    }
}
