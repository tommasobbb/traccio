/// Envelope for the category list returned by `GET /categories`.
///
/// Mirrors the `CategoriesResponse` schema in `docs/api/openapi.json`. A
/// wrapper object rather than a bare array leaves room for pagination
/// metadata later without breaking decoding — same reasoning as
/// `AccountsResponse`.
public struct CategoriesResponse: Codable, Sendable {
    public let categories: [CategoryResponse]

    public init(categories: [CategoryResponse]) {
        self.categories = categories
    }
}
