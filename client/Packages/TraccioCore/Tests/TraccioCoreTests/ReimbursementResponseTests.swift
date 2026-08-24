import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the reimbursements payload.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented ids,
/// round amounts, `"Marco via bonifico"` as a note. Pins the wire contract:
/// field name mapping, both the manual-cash (`transaction_id: null`) and
/// linked shapes, and every required field being genuinely required.
struct ReimbursementResponseTests {
    private static let envelope = """
        {
          "reimbursements": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "advance_id": "22222222-2222-2222-2222-222222222222",
              "amount": 1800,
              "currency": "EUR",
              "transaction_id": null,
              "participant_id": "44444444-4444-4444-4444-444444444444",
              "note": "Marco via bonifico",
              "created_at": "2026-08-18T21:40:00+00:00"
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingFieldsAndACashEntry() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            ReimbursementsResponse.self, from: Data(Self.envelope.utf8)
        )

        #expect(response.reimbursements.count == 1)
        let reimbursement = response.reimbursements[0]
        #expect(reimbursement.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(reimbursement.advanceID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(reimbursement.amount == 1800)
        #expect(reimbursement.currency == "EUR")
        #expect(reimbursement.transactionID == nil)
        #expect(reimbursement.participantID == UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        #expect(reimbursement.note == "Marco via bonifico")
    }

    @Test func decodesALinkedTransactionID() throws {
        let transactionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let json = """
            { "reimbursements": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "advance_id": "22222222-2222-2222-2222-222222222222",
              "amount": 1800,
              "currency": "EUR",
              "transaction_id": "\(transactionID.uuidString)",
              "participant_id": null,
              "note": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            ReimbursementsResponse.self, from: Data(json.utf8)
        )
        #expect(response.reimbursements[0].transactionID == transactionID)
        #expect(response.reimbursements[0].participantID == nil)
        #expect(response.reimbursements[0].note == nil)
    }

    @Test func decodesWhenParticipantIDKeyIsAbsentEntirely() throws {
        // The backend always emits `participant_id` (nullable, never
        // omitted), but the field stays decode-safe against a missing key
        // too, same discipline as `TransactionResponse.eventID`.
        let json = """
            { "reimbursements": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "advance_id": "22222222-2222-2222-2222-222222222222",
              "amount": 1800,
              "currency": "EUR",
              "transaction_id": null,
              "note": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            ReimbursementsResponse.self, from: Data(json.utf8)
        )
        #expect(response.reimbursements[0].participantID == nil)
    }

    @Test func rejectsMissingRequiredField() {
        // `currency` omitted — every field on the wire is required (`note`,
        // `transaction_id` and `participant_id` are required-but-nullable,
        // still present).
        let json = """
            { "reimbursements": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "advance_id": "22222222-2222-2222-2222-222222222222",
              "amount": 1800,
              "transaction_id": null,
              "participant_id": null,
              "note": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(ReimbursementsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyReimbursementsAsAValidState() throws {
        let json = """
            { "reimbursements": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            ReimbursementsResponse.self, from: Data(json.utf8)
        )
        #expect(response.reimbursements.isEmpty)
    }
}
