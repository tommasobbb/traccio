/// Body for `POST /categories/{id}/rename`.
///
/// Mirrors the `RenameCategoryRequest` schema in `docs/api/openapi.json`. Kept
/// distinct from `CreateCategoryRequest` — see that type's docstring.
///
/// No `CodingKeys`: the wire name equals the property name.
public struct RenameCategoryRequest: Encodable, Sendable {
    /// The new name.
    public let name: String

    public init(name: String) {
        self.name = name
    }
}
