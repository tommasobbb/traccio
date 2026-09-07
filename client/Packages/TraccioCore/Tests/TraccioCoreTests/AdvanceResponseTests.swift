import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the advances payload.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): round amounts,
/// invented participant names. They pin the wire contract: field name
/// mapping, the `AdvanceStatus` enum, empty `participants` as a valid state,
/// and every required field being genuinely required.
struct AdvanceResponseTests {
    /// A representative `GET /advances` envelope: one open advance with two
    /// participants, plus the cross-advance `summary` (ADR 0026).
    private static let envelope = """
        {
          "summary": {
            "by_person": [
              {
                "name": "Marco",
                "currency": "EUR",
                "expected": 1800,
                "reimbursed": 1800,
                "outstanding": 0,
                "advance_count": 1
              },
              {
                "name": "Giulia",
                "currency": "EUR",
                "expected": 1800,
                "reimbursed": 0,
                "outstanding": 1800,
                "advance_count": 1
              }
            ],
            "totals": [
              { "currency": "EUR", "outstanding": 1800, "open_advances": 1 }
            ]
          },
          "advances": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1800,
              "receivable": 3600,
              "reimbursed": 1800,
              "outstanding": 1800,
              "excess": 0,
              "currency": "EUR",
              "status": "open",
              "participants": [
                {
                  "id": "33333333-3333-3333-3333-333333333333",
                  "name": "Marco",
                  "expected_amount": 1800,
                  "reimbursed": 1800,
                  "outstanding": 0,
                  "excess": 0,
                  "status": "settled"
                },
                {
                  "id": "44444444-4444-4444-4444-444444444444",
                  "name": "Giulia",
                  "expected_amount": 1800,
                  "reimbursed": 0,
                  "outstanding": 1800,
                  "excess": 0,
                  "status": "outstanding"
                }
              ],
              "created_at": "2026-08-18T21:40:00+00:00"
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingFieldsAndParticipants() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            AdvancesResponse.self,
            from: Data(Self.envelope.utf8)
        )

        #expect(response.advances.count == 1)

        let advance = response.advances[0]
        #expect(advance.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(advance.transactionID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(advance.ownShare == 1800)
        #expect(advance.receivable == 3600)
        #expect(advance.reimbursed == 1800)
        #expect(advance.outstanding == 1800)
        #expect(advance.excess == 0)
        #expect(advance.currency == "EUR")
        #expect(advance.status == .open)
        #expect(advance.participants.count == 2)
        let marco = advance.participants[0]
        #expect(marco.id == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(marco.name == "Marco")
        #expect(marco.expectedAmount == 1800)
        #expect(marco.reimbursed == 1800)
        #expect(marco.outstanding == 0)
        #expect(marco.excess == 0)
        #expect(marco.status == .settled)
        #expect(advance.participants[1].status == .outstanding)

        // The cross-advance summary rides in the same envelope (ADR 0026).
        #expect(response.summary.byPerson.count == 2)
        let marcoSummary = response.summary.byPerson[0]
        #expect(marcoSummary.name == "Marco")
        #expect(marcoSummary.currency == "EUR")
        #expect(marcoSummary.expected == 1800)
        #expect(marcoSummary.reimbursed == 1800)
        #expect(marcoSummary.outstanding == 0)
        #expect(marcoSummary.advanceCount == 1)
        #expect(response.summary.byPerson[1].name == "Giulia")
        #expect(response.summary.totals.count == 1)
        #expect(response.summary.totals[0].currency == "EUR")
        #expect(response.summary.totals[0].outstanding == 1800)
        #expect(response.summary.totals[0].openAdvances == 1)
    }

    @Test func rejectsSummaryMissingRequiredField() {
        // `advance_count` omitted from a person row — every summary field is
        // required, same discipline as the advance rows.
        let json = """
            {
              "summary": {
                "by_person": [
                  {
                    "name": "Marco",
                    "currency": "EUR",
                    "expected": 1800,
                    "reimbursed": 0,
                    "outstanding": 1800
                  }
                ],
                "totals": []
              },
              "advances": []
            }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(AdvancesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsMissingSummary() {
        // The envelope without `summary` is not a valid `GET /advances` body.
        let json = """
            { "advances": [] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(AdvancesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownParticipantStatus() {
        let json = """
            { "summary": { "by_person": [], "totals": [] }, "advances": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1000,
              "receivable": 0,
              "reimbursed": 0,
              "outstanding": 0,
              "excess": 0,
              "currency": "EUR",
              "status": "open",
              "participants": [ {
                "id": "33333333-3333-3333-3333-333333333333",
                "name": "Marco",
                "expected_amount": 1800,
                "reimbursed": 0,
                "outstanding": 1800,
                "excess": 0,
                "status": "forgiven"
              } ],
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(AdvancesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyParticipantsAsAValidState() throws {
        let json = """
            { "summary": { "by_person": [], "totals": [] }, "advances": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1000,
              "receivable": 0,
              "reimbursed": 0,
              "outstanding": 0,
              "excess": 0,
              "currency": "EUR",
              "status": "open",
              "participants": [],
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            AdvancesResponse.self, from: Data(json.utf8)
        )
        #expect(response.advances[0].participants.isEmpty)
    }

    @Test func decodesWrittenOffAndSettledStatus() throws {
        for (raw, expected) in [("settled", AdvanceStatus.settled), ("written_off", .writtenOff)] {
            let json = """
                { "summary": { "by_person": [], "totals": [] }, "advances": [ {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "transaction_id": "22222222-2222-2222-2222-222222222222",
                  "own_share": 1000,
                  "receivable": 500,
                  "reimbursed": 500,
                  "outstanding": 0,
                  "excess": 0,
                  "currency": "EUR",
                  "status": "\(raw)",
                  "participants": [],
                  "created_at": "2026-08-18T21:40:00+00:00"
                } ] }
                """
            let response = try TraccioCore.jsonDecoder().decode(
                AdvancesResponse.self, from: Data(json.utf8)
            )
            #expect(response.advances[0].status == expected)
        }
    }

    @Test func rejectsUnknownStatus() {
        let json = """
            { "summary": { "by_person": [], "totals": [] }, "advances": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1000,
              "receivable": 0,
              "reimbursed": 0,
              "outstanding": 0,
              "excess": 0,
              "currency": "EUR",
              "status": "forgiven",
              "participants": [],
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(AdvancesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsMissingRequiredField() {
        // `excess` omitted — every field on the wire is required.
        let json = """
            { "summary": { "by_person": [], "totals": [] }, "advances": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1000,
              "receivable": 0,
              "reimbursed": 0,
              "outstanding": 0,
              "currency": "EUR",
              "status": "open",
              "participants": [],
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(AdvancesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyAdvancesAsAValidState() throws {
        let json = """
            { "summary": { "by_person": [], "totals": [] }, "advances": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            AdvancesResponse.self, from: Data(json.utf8)
        )
        #expect(response.advances.isEmpty)
    }
}
