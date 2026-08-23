import Foundation

/// Body for `POST /transactions/{id}/category`.
///
/// Mirrors the `ConfirmCategoryRequest` schema in `docs/api/openapi.json`.
/// `CodingKeys` spell the wire name explicitly, following every response
/// model's convention (`TransactionResponse`, `CategoryResponse`) rather than
/// leaning on an encoder-wide case-conversion strategy.
public struct ConfirmCategoryRequest: Encodable, Sendable {
    /// The category to confirm. Must belong to the caller.
    public let categoryID: UUID

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
    }

    public init(categoryID: UUID) {
        self.categoryID = categoryID
    }
}
