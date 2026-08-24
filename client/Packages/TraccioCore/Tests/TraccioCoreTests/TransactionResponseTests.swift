import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the transactions payload.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented
/// merchants, round amounts. They pin the wire contract: field name mapping,
/// the `TransactionRole`/`TransactionStatus` enums, `null` handling, and
/// every required field being genuinely required. A backend field rename or
/// a new enum case breaks these rather than surfacing as a runtime surprise.
struct TransactionResponseTests {
    /// A representative `GET /transactions` envelope: a personal spend and an
    /// advance, covering both nullable-category states.
    private static let envelope = """
        {
          "transactions": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -1230,
              "effective_amount": -1230,
              "currency": "EUR",
              "booked_at": "2026-08-20T09:30:00+00:00",
              "value_date": "2026-08-19T00:00:00",
              "description": "TEST MERCHANT 01",
              "display_description": null,
              "status": "booked",
              "role": "personal",
              "suggested_category_id": "33333333-3333-3333-3333-333333333333",
              "confirmed_category_id": null,
              "effective_category_id": "33333333-3333-3333-3333-333333333333",
              "event_id": "66666666-6666-6666-6666-666666666666"
            },
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -5400,
              "effective_amount": -1800,
              "currency": "EUR",
              "booked_at": null,
              "value_date": null,
              "description": "TEST RESTAURANT 02",
              "display_description": "Test Restaurant",
              "status": "pending",
              "role": "advance",
              "suggested_category_id": null,
              "confirmed_category_id": "55555555-5555-5555-5555-555555555555",
              "effective_category_id": "55555555-5555-5555-5555-555555555555",
              "event_id": null
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingFieldsAndSign() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            TransactionsResponse.self,
            from: Data(Self.envelope.utf8)
        )

        #expect(response.transactions.count == 2)

        let personal = response.transactions[0]
        #expect(personal.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(personal.accountID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(personal.amount == -1230)
        #expect(personal.effectiveAmount == -1230)
        #expect(personal.currency == "EUR")
        #expect(personal.bookedAt != nil)
        #expect(personal.description == "TEST MERCHANT 01")
        #expect(personal.displayDescription == nil)
        #expect(personal.status == .booked)
        #expect(personal.role == .personal)
        #expect(personal.suggestedCategoryID != nil)
        #expect(personal.confirmedCategoryID == nil)
        #expect(personal.effectiveCategoryID == personal.suggestedCategoryID)
        #expect(personal.eventID == UUID(uuidString: "66666666-6666-6666-6666-666666666666"))

        let advance = response.transactions[1]
        #expect(advance.bookedAt == nil)
        #expect(advance.valueDate == nil)
        #expect(advance.displayDescription == "Test Restaurant")
        #expect(advance.status == .pending)
        #expect(advance.role == .advance)
        // An advance's effective_amount is the declared share, not the full
        // amount — the client never recomputes this, just renders it.
        #expect(advance.amount == -5400)
        #expect(advance.effectiveAmount == -1800)
        #expect(advance.suggestedCategoryID == nil)
        #expect(advance.confirmedCategoryID != nil)
        #expect(advance.effectiveCategoryID == advance.confirmedCategoryID)
        #expect(advance.eventID == nil)
    }

    @Test func decodesWhenEventIDKeyIsAbsentEntirely() throws {
        // The backend always emits `event_id` (nullable, never omitted), but
        // the field stays `decodeIfPresent`-safe against a missing key too.
        let json = """
            { "transactions": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -100,
              "effective_amount": -100,
              "currency": "EUR",
              "booked_at": null,
              "value_date": null,
              "description": "TEST MERCHANT 01",
              "display_description": null,
              "status": "booked",
              "role": "personal",
              "suggested_category_id": null,
              "confirmed_category_id": null,
              "effective_category_id": null
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            TransactionsResponse.self, from: Data(json.utf8)
        )
        #expect(response.transactions[0].eventID == nil)
    }

    @Test func rejectsMalformedEventID() {
        let json = """
            { "transactions": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -100,
              "effective_amount": -100,
              "currency": "EUR",
              "booked_at": null,
              "value_date": null,
              "description": "TEST MERCHANT 01",
              "display_description": null,
              "status": "booked",
              "role": "personal",
              "suggested_category_id": null,
              "confirmed_category_id": null,
              "effective_category_id": null,
              "event_id": "not-a-uuid"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransactionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownRole() {
        let json = """
            { "transactions": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -100,
              "effective_amount": -100,
              "currency": "EUR",
              "booked_at": null,
              "value_date": null,
              "description": "TEST MERCHANT 01",
              "display_description": null,
              "status": "booked",
              "role": "loan",
              "suggested_category_id": null,
              "confirmed_category_id": null,
              "effective_category_id": null
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransactionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownStatus() {
        let json = """
            { "transactions": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -100,
              "effective_amount": -100,
              "currency": "EUR",
              "booked_at": null,
              "value_date": null,
              "description": "TEST MERCHANT 01",
              "display_description": null,
              "status": "cancelled",
              "role": "personal",
              "suggested_category_id": null,
              "confirmed_category_id": null,
              "effective_category_id": null
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransactionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsMissingRequiredField() {
        // `role` omitted — every field on the wire is required.
        let json = """
            { "transactions": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -100,
              "effective_amount": -100,
              "currency": "EUR",
              "booked_at": null,
              "value_date": null,
              "description": "TEST MERCHANT 01",
              "display_description": null,
              "status": "booked",
              "suggested_category_id": null,
              "confirmed_category_id": null,
              "effective_category_id": null
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(TransactionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyTransactionsAsAValidState() throws {
        let json = """
            { "transactions": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            TransactionsResponse.self, from: Data(json.utf8)
        )
        #expect(response.transactions.isEmpty)
    }
}
