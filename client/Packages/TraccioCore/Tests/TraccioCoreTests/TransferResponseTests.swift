import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the transfer-suggestion and confirmed-transfer
/// payloads.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented ids,
/// round amounts. They pin the wire contract, including the negative cases
/// `client/CLAUDE.md` requires (a malformed id, a missing required field).
struct TransferResponseTests {
    // MARK: TransferSuggestionsResponse

    private static let suggestionsEnvelope = """
        { "suggestions": [
          {
            "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
            "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
            "currency": "EUR",
            "outgoing_amount": -25000,
            "incoming_amount": 24950,
            "amount_delta": 50,
            "day_gap": 1
          }
        ] }
        """

    @Test func decodesSuggestionEnvelopePreservingFields() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransferSuggestionsResponse.self, from: Data(Self.suggestionsEnvelope.utf8)
        )

        #expect(response.suggestions.count == 1)
        let suggestion = response.suggestions[0]
        #expect(suggestion.outgoingTransactionID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(suggestion.incomingTransactionID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(suggestion.currency == "EUR")
        #expect(suggestion.outgoingAmount == -25000)
        #expect(suggestion.incomingAmount == 24950)
        #expect(suggestion.amountDelta == 50)
        #expect(suggestion.dayGap == 1)
    }

    @Test func decodesEmptySuggestionsAsAValidState() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransferSuggestionsResponse.self, from: Data(#"{ "suggestions": [] }"#.utf8)
        )
        #expect(response.suggestions.isEmpty)
    }

    @Test func rejectsAMalformedSuggestionID() {
        let json = """
            { "suggestions": [ {
              "outgoing_transaction_id": "not-a-uuid",
              "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
              "currency": "EUR",
              "outgoing_amount": -25000,
              "incoming_amount": 25000,
              "amount_delta": 0,
              "day_gap": 0
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransferSuggestionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsASuggestionMissingARequiredField() {
        // `day_gap` omitted — every field on the wire is required.
        let json = """
            { "suggestions": [ {
              "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
              "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
              "currency": "EUR",
              "outgoing_amount": -25000,
              "incoming_amount": 25000,
              "amount_delta": 0
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransferSuggestionsResponse.self, from: Data(json.utf8))
        }
    }

    // MARK: TransfersResponse

    private static let transfersEnvelope = """
        { "transfers": [
          {
            "id": "33333333-3333-3333-3333-333333333333",
            "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
            "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
            "created_at": "2026-08-20T09:30:00+00:00"
          }
        ] }
        """

    @Test func decodesTransferEnvelopePreservingFields() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransfersResponse.self, from: Data(Self.transfersEnvelope.utf8)
        )

        #expect(response.transfers.count == 1)
        let transfer = response.transfers[0]
        #expect(transfer.id == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(transfer.outgoingTransactionID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(transfer.incomingTransactionID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    }

    @Test func decodesEmptyTransfersAsAValidState() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransfersResponse.self, from: Data(#"{ "transfers": [] }"#.utf8)
        )
        #expect(response.transfers.isEmpty)
    }

    @Test func rejectsATransferMissingARequiredField() {
        // `created_at` omitted — every field on the wire is required.
        let json = """
            { "transfers": [ {
              "id": "33333333-3333-3333-3333-333333333333",
              "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
              "incoming_transaction_id": "22222222-2222-2222-2222-222222222222"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransfersResponse.self, from: Data(json.utf8))
        }
    }
}
