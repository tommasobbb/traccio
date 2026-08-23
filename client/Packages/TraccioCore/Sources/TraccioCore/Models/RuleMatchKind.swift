/// The predicate a categorization rule applies to a transaction's
/// `description`.
///
/// Mirrors the `RuleMatchKind` schema in `docs/api/openapi.json`. Raw values
/// match the wire format exactly, so an unknown value fails to decode rather
/// than being silently dropped — the same discipline as `AccountKind` and
/// `AdvanceStatus`. Matching itself is entirely server-side
/// (`domain/rules.py::rule_matches`); the client never re-implements it (see
/// `.claude/rules/swift.md`: "the backend owns every derived value").
public enum RuleMatchKind: String, Codable, Sendable, CaseIterable {
    /// The pattern appears anywhere in the description.
    case contains
    /// The description begins with the pattern.
    case startsWith = "starts_with"
    /// The description equals the pattern exactly.
    case equals
}
