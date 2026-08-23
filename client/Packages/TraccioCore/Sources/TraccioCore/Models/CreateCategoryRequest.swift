/// Body for `POST /categories`.
///
/// Mirrors the `CreateCategoryRequest` schema in `docs/api/openapi.json`. A
/// separate type from `RenameCategoryRequest` despite the identical wire
/// shape today, because the two are distinct backend schemas
/// (`api/schemas/categories.py`) that may diverge later — the same reasoning
/// as `ConfirmTransferRequest`/`RejectTransferRequest`.
///
/// No `CodingKeys`: the wire name equals the property name. The backend
/// validates length and blankness (`domain/categories.py::normalize_category_name`)
/// and uniqueness; the client does not re-check either, letting a `422`/`409`
/// surface instead (`.claude/rules/swift.md`).
public struct CreateCategoryRequest: Encodable, Sendable {
    /// The category's name, e.g. `"Alimentari"`.
    public let name: String

    public init(name: String) {
        self.name = name
    }
}
