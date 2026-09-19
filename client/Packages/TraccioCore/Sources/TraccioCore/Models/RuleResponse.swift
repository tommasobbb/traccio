import Foundation

/// One categorization rule as returned by `GET /rules`.
///
/// Mirrors the `RuleResponse` schema in `docs/api/openapi.json`. A rule maps
/// a transaction pattern to a category and has no edit endpoint by design
/// (ADR 0005: its two fields are what makes it a distinct rule at all —
/// "editing" one is delete-and-recreate).
public struct RuleResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable rule identifier.
    public let id: UUID
    /// The category assigned when this rule matches.
    public let categoryID: UUID
    /// The predicate applied to a transaction's raw `description`.
    public let matchKind: RuleMatchKind
    /// The text matched against — merchant/counterparty text, never logged
    /// (`docs/engineering.md`).
    public let pattern: String
    /// When the rule was created.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case categoryID = "category_id"
        case matchKind = "match_kind"
        case pattern
        case createdAt = "created_at"
    }

    public init(id: UUID, categoryID: UUID, matchKind: RuleMatchKind, pattern: String, createdAt: Date) {
        self.id = id
        self.categoryID = categoryID
        self.matchKind = matchKind
        self.pattern = pattern
        self.createdAt = createdAt
    }
}
