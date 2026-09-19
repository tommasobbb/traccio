import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the transfer-suggestion and confirmed-transfer
/// payloads.
///
/// Fixtures are synthetic (`docs/engineering.md`): invented ids,
/// round amounts. They pin the wire contract, including the negative cases
/// `docs/engineering.md` requires (a malformed id, a missing required field).
struct TransferResponseTests {
    // MARK: TransferSuggestionsResponse

    /// A full `TransactionResponse` object, as embedded in a suggestion's
    /// `outgoing` / `incoming` — the same shape `GET /transactions` returns.
    private static func leg(id: String, amount: Int) -> String {
        """
        {
          "id": "\(id)",
          "account_id": "99999999-9999-9999-9999-999999999999",
          "amount": \(amount),
          "effective_amount": \(amount),
          "currency": "EUR",
          "booked_at": "2026-08-20T09:30:00+00:00",
          "value_date": null,
          "description": "TEST MERCHANT 01",
          "display_description": null,
          "status": "booked",
          "role": "personal",
          "suggested_category_id": null,
          "confirmed_category_id": null,
          "effective_category_id": null,
          "event_id": null
        }
        """
    }

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
            "day_gap": 1,
            "outgoing": \(Self.leg(id: "11111111-1111-1111-1111-111111111111", amount: -25000)),
            "incoming": \(Self.leg(id: "22222222-2222-2222-2222-222222222222", amount: 24950))
          },
          {
            "kind": "funded_payment",
            "outgoing_transaction_id": "55555555-5555-5555-5555-555555555555",
            "incoming_transaction_id": "66666666-6666-6666-6666-666666666666",
            "currency": "EUR",
            "outgoing_amount": -1290,
            "incoming_amount": -1290,
            "amount_delta": 0,
            "day_gap": 0,
            "outgoing": \(Self.leg(id: "55555555-5555-5555-5555-555555555555", amount: -1290)),
            "incoming": \(Self.leg(id: "66666666-6666-6666-6666-666666666666", amount: -1290))
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
        // The embedded legs decode as full transactions.
        #expect(suggestion.outgoing.id == suggestion.outgoingTransactionID)
        #expect(suggestion.outgoing.amount == -25000)
        #expect(suggestion.incoming.id == suggestion.incomingTransactionID)
        #expect(suggestion.incoming.amount == 24950)

        // A funded payment: both legs are outflows.
        let funded = response.suggestions[1]
        #expect(funded.kind == .fundedPayment)
        #expect(funded.outgoingAmount == -1290)
        #expect(funded.incomingAmount == -1290)
        #expect(funded.incoming.amount == -1290)
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
              "day_gap": 0,
              "outgoing": \(Self.leg(id: "11111111-1111-1111-1111-111111111111", amount: -25000)),
              "incoming": \(Self.leg(id: "22222222-2222-2222-2222-222222222222", amount: 25000))
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
              "day_gap": 0,
              "outgoing": \(Self.leg(id: "11111111-1111-1111-1111-111111111111", amount: -25000)),
              "incoming": \(Self.leg(id: "22222222-2222-2222-2222-222222222222", amount: 25000))
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
              "amount_delta": 0,
              "outgoing": \(Self.leg(id: "11111111-1111-1111-1111-111111111111", amount: -25000)),
              "incoming": \(Self.leg(id: "22222222-2222-2222-2222-222222222222", amount: 25000))
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransferSuggestionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsASuggestionMissingAnEmbeddedLeg() {
        // `incoming` omitted — the embedded legs are required too.
        let json = """
            { "suggestions": [ {
              "kind": "two_sided",
              "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
              "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
              "currency": "EUR",
              "outgoing_amount": -25000,
              "incoming_amount": 25000,
              "amount_delta": 0,
              "day_gap": 0,
              "outgoing": \(Self.leg(id: "11111111-1111-1111-1111-111111111111", amount: -25000))
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
