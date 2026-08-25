import Foundation

/// Body for `POST /categories/{id}/move`.
///
/// Mirrors the `MoveCategoryRequest` schema in `docs/api/openapi.json`.
/// `parentID` is mandatory-but-nullable on the backend — `nil` explicitly
/// makes the category a root, rather than being an absent field — so a
/// hand-written `encode(to:)` is required (see `RenameAccountRequest`'s doc
/// comment for the full explanation of why the synthesized conformance would
/// omit the key instead).
public struct MoveCategoryRequest: Encodable, Sendable {
    /// The new parent, or `nil` to make this category a root.
    public let parentID: UUID?

    public init(parentID: UUID?) {
        self.parentID = parentID
    }

    private enum CodingKeys: String, CodingKey {
        case parentID = "parent_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parentID, forKey: .parentID)
    }
}
