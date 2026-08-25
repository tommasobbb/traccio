/// Body for `POST /accounts/{id}/appearance`.
///
/// Mirrors the `SetAccountAppearanceRequest` schema in
/// `docs/api/openapi.json`. A full replace: both fields are mandatory on the
/// backend but individually nullable, to allow clearing either. A
/// hand-written `encode(to:)` is required: Swift's synthesized `Encodable`
/// conformance uses `encodeIfPresent` for an `Optional` stored property,
/// which *omits* the key entirely when the value is `nil` — the wrong shape
/// for fields the backend requires to always be present (see
/// `RenameAccountRequest`'s doc comment for the full explanation). Calling
/// `encode(_:forKey:)` directly writes an explicit JSON `null` instead.
public struct SetAccountAppearanceRequest: Encodable, Sendable {
    /// The new colour, or `nil` to clear it.
    public let color: PaletteColor?
    /// The new icon, or `nil` to clear it.
    public let icon: AccountIcon?

    public init(color: PaletteColor?, icon: AccountIcon?) {
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
