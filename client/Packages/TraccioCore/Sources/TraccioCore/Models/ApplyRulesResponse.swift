/// The result of recomputing every rule against the caller's transactions,
/// from `POST /rules/apply`.
///
/// Mirrors the `ApplyRulesResponse` schema in `docs/api/openapi.json`.
///
/// `matched`/`cleared` are **not** a change count — the backend recomputes
/// every one of the caller's transactions on every call
/// (`db/repositories.py::set_suggested_categories`), so
/// `matched + cleared` always equals the total transaction count, and
/// `cleared` counts rows that ended up with no suggestion, not rows whose
/// prior suggestion was removed. A caller must not present these as "N
/// changed" — see the `applyRules()` call sites for the honest phrasing
/// ("N movimenti su M hanno un suggerimento").
public struct ApplyRulesResponse: Codable, Sendable, Equatable {
    /// How many of the caller's rules were evaluated.
    public let rulesApplied: Int
    /// How many transactions ended up with a suggested category.
    public let matched: Int
    /// How many transactions ended up with no suggested category.
    public let cleared: Int

    private enum CodingKeys: String, CodingKey {
        case rulesApplied = "rules_applied"
        case matched
        case cleared
    }

    public init(rulesApplied: Int, matched: Int, cleared: Int) {
        self.rulesApplied = rulesApplied
        self.matched = matched
        self.cleared = cleared
    }
}
