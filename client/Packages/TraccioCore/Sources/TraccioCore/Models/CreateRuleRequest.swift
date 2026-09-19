import Foundation

/// Body for `POST /rules`.
///
/// Mirrors the `CreateRuleRequest` schema in `docs/api/openapi.json`.
/// `CodingKeys` spell the wire name explicitly, following every other
/// request model's convention (`ConfirmCategoryRequest`, `CreateAdvanceRequest`)
/// rather than leaning on an encoder-wide case-conversion strategy.
///
/// The backend validates the pattern's length and normalizes it
/// (`domain/rules.py::normalize_rule_pattern`); the client sends the raw
/// typed text and lets a `422` surface if it is blank or too long, rather
/// than re-implementing that check (see `docs/engineering.md`). Likewise
/// for uniqueness: a duplicate `(match_kind, pattern)` surfaces as a `409`
/// the client did not predict.
public struct CreateRuleRequest: Encodable, Sendable {
    /// The category to assign when this rule matches. Must belong to the
    /// caller.
    public let categoryID: UUID
    /// The predicate to apply to a transaction's `description`.
    public let matchKind: RuleMatchKind
    /// The text to match against.
    public let pattern: String

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case matchKind = "match_kind"
        case pattern
    }

    public init(categoryID: UUID, matchKind: RuleMatchKind, pattern: String) {
        self.categoryID = categoryID
        self.matchKind = matchKind
        self.pattern = pattern
    }
}
