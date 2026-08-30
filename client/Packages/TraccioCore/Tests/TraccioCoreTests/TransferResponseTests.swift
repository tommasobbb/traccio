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
            "kind": "two_sided",
            "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
            "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
            "currency": "EUR",
            "outgoing_amount": -25000,
            "incoming_amount": 24950,
            "amount_delta": 50,
            "day_gap": 1
          },
          {
            "kind": "funded_payment",
            "outgoing_transaction_id": "55555555-5555-5555-5555-555555555555",
            "incoming_transaction_id": "66666666-6666-6666-6666-666666666666",
            "currency": "EUR",
            "outgoing_amount": -1290,
            "incoming_amount": -1290,
            "amount_delta": 0,
            "day_gap": 0
          }
        ] }
        """

    @Test func decodesSuggestionEnvelopePreservingFields() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransferSuggestionsResponse.self, from: Data(Self.suggestionsEnvelope.utf8)
        )

        #expect(response.suggestions.count == 2)
        let suggestion = response.suggestions[0]
        #expect(suggestion.kind == .twoSided)
        #expect(suggestion.outgoingTransactionID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(suggestion.incomingTransactionID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(suggestion.currency == "EUR")
        #expect(suggestion.outgoingAmount == -25000)
        #expect(suggestion.incomingAmount == 24950)
        #expect(suggestion.amountDelta == 50)
        #expect(suggestion.dayGap == 1)

        // A funded payment: both legs are outflows.
        let funded = response.suggestions[1]
        #expect(funded.kind == .fundedPayment)
        #expect(funded.outgoingAmount == -1290)
        #expect(funded.incomingAmount == -1290)
    }

    @Test func rejectsAnUnknownSuggestionKind() {
        let json = """
            { "suggestions": [ {
              "kind": "wormhole",
              "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
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

    @Test func decodesEmptySuggestionsAsAValidState() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransferSuggestionsResponse.self, from: Data(#"{ "suggestions": [] }"#.utf8)
        )
        #expect(response.suggestions.isEmpty)
    }

    @Test func rejectsAMalformedSuggestionID() {
        let json = """
            { "suggestions": [ {
              "kind": "two_sided",
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
              "kind": "two_sided",
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
            "kind": "two_sided",
            "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
            "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
            "created_at": "2026-08-20T09:30:00+00:00"
          },
          {
            "id": "44444444-4444-4444-4444-444444444444",
            "kind": "funded_payment",
            "outgoing_transaction_id": "55555555-5555-5555-5555-555555555555",
            "incoming_transaction_id": "66666666-6666-6666-6666-666666666666",
            "created_at": "2026-08-21T10:00:00+00:00"
          }
        ] }
        """

    @Test func decodesTransferEnvelopePreservingFields() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransfersResponse.self, from: Data(Self.transfersEnvelope.utf8)
        )

        #expect(response.transfers.count == 2)
        let transfer = response.transfers[0]
        #expect(transfer.id == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(transfer.kind == .twoSided)
        #expect(transfer.outgoingTransactionID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(transfer.incomingTransactionID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(response.transfers[1].kind == .fundedPayment)
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
              "kind": "two_sided",
              "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
              "incoming_transaction_id": "22222222-2222-2222-2222-222222222222"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransfersResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsAnUnknownTransferKind() {
        let json = """
            { "transfers": [ {
              "id": "33333333-3333-3333-3333-333333333333",
              "kind": "wormhole",
              "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
              "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
              "created_at": "2026-08-20T09:30:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransfersResponse.self, from: Data(json.utf8))
        }
    }
}
