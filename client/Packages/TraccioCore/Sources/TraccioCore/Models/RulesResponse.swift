/// Envelope for the rules list.
///
/// Mirrors the `RulesResponse` schema in `docs/api/openapi.json`. `rules` is
/// in **evaluation order** — the longest pattern wins, ties broken by
/// creation time then id (ADR 0005) — not creation order. The client renders
/// this order as-is and never re-sorts locally: doing so would be a Swift
/// copy of `services/categorization.py::evaluation_order`, exactly the kind
/// of derived value `docs/engineering.md` reserves for the backend.
public struct RulesResponse: Codable, Sendable, Equatable {
    /// The user's rules, in evaluation order (empty if none).
    public let rules: [RuleResponse]

    public init(rules: [RuleResponse]) {
        self.rules = rules
    }
}
