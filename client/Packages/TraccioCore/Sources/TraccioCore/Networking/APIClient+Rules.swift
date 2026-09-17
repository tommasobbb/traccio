import Foundation

/// Categorization-rule endpoints — one slice of `APIClientProtocol`.
public protocol RulesAPI: Sendable {
    func rules() async throws -> [RuleResponse]
    func createRule(_ request: CreateRuleRequest) async throws -> RuleResponse
    func deleteRule(id: UUID) async throws
    func applyRules() async throws -> ApplyRulesResponse
}

// Categorization-rule endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient: RulesAPI {
    /// Fetch the caller's categorization rules, in evaluation order.
    ///
    /// Mirrors `GET /rules` (ADR 0005). The order is the order rules actually
    /// fire in (longest pattern wins) — not creation order, and never
    /// re-sorted client-side.
    ///
    /// Returns
    /// -------
    /// The decoded rules, in evaluation order (empty if none).
    public func rules() async throws -> [RuleResponse] {
        let envelope: RulesResponse = try await get("rules")
        return envelope.rules
    }

    /// Create a categorization rule.
    ///
    /// Mirrors `POST /rules`, `201 Created` with the created rule. A `404` if
    /// the target category is unknown or not the caller's; a `422` if the
    /// pattern is blank or too long; a `409 rule_already_exists` if the
    /// (normalized) `(matchKind, pattern)` collides with one of the caller's
    /// existing rules.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The target category, predicate, and pattern.
    ///
    /// Returns
    /// -------
    /// The created rule.
    public func createRule(_ request: CreateRuleRequest) async throws -> RuleResponse {
        try await post("rules", body: request)
    }

    /// Delete a categorization rule.
    ///
    /// Mirrors `DELETE /rules/{id}`, `204 No Content` on success. A `404` if
    /// the rule is unknown or not the caller's. Rules have no edit endpoint
    /// by design (ADR 0005): there is no update counterpart to this method.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The rule to delete.
    public func deleteRule(id: UUID) async throws {
        try await delete("rules/\(id.uuidString)")
    }

    /// Recompute every one of the caller's rules against every one of their
    /// transactions.
    ///
    /// Mirrors `POST /rules/apply`, `200` with counts. A full, idempotent
    /// recompute (ADR 0005) — never incremental — that writes only
    /// `suggested_category_id`, never `confirmed_category_id`. See
    /// `ApplyRulesResponse`'s docstring: the counts are a snapshot of the
    /// whole pool, not a change count.
    ///
    /// Returns
    /// -------
    /// How many rules were evaluated, and how many transactions ended up
    /// matched vs. cleared.
    public func applyRules() async throws -> ApplyRulesResponse {
        try await post("rules/apply")
    }
}
