import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the rules payload family: `RulesResponse`
/// (`GET /rules`) and `ApplyRulesResponse` (`POST /rules/apply`).
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented
/// patterns like `"TEST MERCHANT 01"`, a rule's pattern being
/// merchant/counterparty text (`api/schemas/rules.py`). They pin the wire
/// contract: field name mapping, all three `RuleMatchKind` cases, the order
/// preserved as-is (evaluation order, never re-sorted — see
/// `RulesResponse`'s docstring), and every required field being genuinely
/// required.
struct RuleResponseTests {
    /// A representative `GET /rules` envelope: two rules, already in
    /// evaluation order (the longer pattern first).
    private static let envelope = """
        {
          "rules": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "category_id": "22222222-2222-2222-2222-222222222222",
              "match_kind": "starts_with",
              "pattern": "TEST MERCHANT 01 SUBSCRIPTION",
              "created_at": "2026-08-24T09:30:00+00:00"
            },
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "category_id": "22222222-2222-2222-2222-222222222222",
              "match_kind": "contains",
              "pattern": "TEST MERCHANT 01",
              "created_at": "2026-08-24T09:31:00+00:00"
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingEvaluationOrderAndFields() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            RulesResponse.self, from: Data(Self.envelope.utf8)
        )

        #expect(response.rules.count == 2)
        let first = response.rules[0]
        #expect(first.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(first.categoryID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(first.matchKind == .startsWith)
        #expect(first.pattern == "TEST MERCHANT 01 SUBSCRIPTION")
        // The longer pattern stays first — the envelope's order is preserved
        // verbatim, never re-sorted by the client.
        #expect(response.rules[1].pattern == "TEST MERCHANT 01")
    }

    @Test func decodesAllThreeMatchKinds() throws {
        for (raw, expected) in [
            ("contains", RuleMatchKind.contains),
            ("starts_with", RuleMatchKind.startsWith),
            ("equals", RuleMatchKind.equals),
        ] {
            let json = """
                { "rules": [ {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "category_id": "22222222-2222-2222-2222-222222222222",
                  "match_kind": "\(raw)",
                  "pattern": "TEST MERCHANT 01",
                  "created_at": "2026-08-24T09:30:00+00:00"
                } ] }
                """
            let response = try TraccioCore.jsonDecoder().decode(
                RulesResponse.self, from: Data(json.utf8)
            )
            #expect(response.rules[0].matchKind == expected)
        }
    }

    @Test func rejectsAnUnknownMatchKind() {
        let json = """
            { "rules": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "category_id": "22222222-2222-2222-2222-222222222222",
              "match_kind": "fuzzy",
              "pattern": "TEST MERCHANT 01",
              "created_at": "2026-08-24T09:30:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(RulesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsAMalformedCreatedAt() {
        let json = """
            { "rules": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "category_id": "22222222-2222-2222-2222-222222222222",
              "match_kind": "contains",
              "pattern": "TEST MERCHANT 01",
              "created_at": "not-a-date"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(RulesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsMissingRequiredField() {
        // `pattern` omitted — every field on the wire is required.
        let json = """
            { "rules": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "category_id": "22222222-2222-2222-2222-222222222222",
              "match_kind": "contains",
              "created_at": "2026-08-24T09:30:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(RulesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyRulesAsAValidState() throws {
        let json = """
            { "rules": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            RulesResponse.self, from: Data(json.utf8)
        )
        #expect(response.rules.isEmpty)
    }

    @Test func decodesApplyResultCounts() throws {
        let json = """
            { "rules_applied": 4, "matched": 128, "cleared": 401 }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            ApplyRulesResponse.self, from: Data(json.utf8)
        )
        #expect(response.rulesApplied == 4)
        #expect(response.matched == 128)
        #expect(response.cleared == 401)
    }
}
