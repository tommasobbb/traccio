import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the events payload.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented ids,
/// round amounts, `"TEST TRIP 01"`. They pin the wire contract: field name
/// mapping, `start_date`/`end_date` as `CalendarDate` (not a full
/// date-time), `currency: null` on an empty event as a valid state, the
/// `EventStatus` enum, and every required field being genuinely required.
struct EventResponseTests {
    /// A representative `GET /events` envelope: one active event with a date
    /// range and a nonzero total.
    private static let envelope = """
        {
          "events": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "TEST TRIP 01",
              "start_date": "2026-08-01",
              "end_date": "2026-08-10",
              "status": "active",
              "member_count": 3,
              "total": -23000,
              "currency": "EUR",
              "created_at": "2026-08-18T21:40:00+00:00"
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingFieldsAndDateRange() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            EventsResponse.self,
            from: Data(Self.envelope.utf8)
        )

        #expect(response.events.count == 1)

        let event = response.events[0]
        #expect(event.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(event.name == "TEST TRIP 01")
        #expect(event.startDate == CalendarDate(year: 2026, month: 8, day: 1))
        #expect(event.endDate == CalendarDate(year: 2026, month: 8, day: 10))
        #expect(event.status == .active)
        #expect(event.memberCount == 3)
        #expect(event.total == -23000)
        #expect(event.currency == "EUR")
    }

    @Test func decodesAnEmptyEventWithNullDatesAndCurrency() throws {
        let json = """
            { "events": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "TEST TRIP 01",
              "start_date": null,
              "end_date": null,
              "status": "active",
              "member_count": 0,
              "total": 0,
              "currency": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(EventsResponse.self, from: Data(json.utf8))
        let event = response.events[0]
        #expect(event.startDate == nil)
        #expect(event.endDate == nil)
        #expect(event.memberCount == 0)
        #expect(event.total == 0)
        #expect(event.currency == nil)
    }

    @Test func decodesClosedStatus() throws {
        let json = """
            { "events": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "TEST TRIP 01",
              "start_date": null,
              "end_date": null,
              "status": "closed",
              "member_count": 0,
              "total": 0,
              "currency": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(EventsResponse.self, from: Data(json.utf8))
        #expect(response.events[0].status == .closed)
    }

    @Test func rejectsUnknownStatus() {
        let json = """
            { "events": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "TEST TRIP 01",
              "start_date": null,
              "end_date": null,
              "status": "archived",
              "member_count": 0,
              "total": 0,
              "currency": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(EventsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsAFullDateTimeInStartDate() {
        // start_date must be a bare yyyy-MM-dd, not a timestamp.
        let json = """
            { "events": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "TEST TRIP 01",
              "start_date": "2026-08-01T00:00:00Z",
              "end_date": null,
              "status": "active",
              "member_count": 0,
              "total": 0,
              "currency": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(EventsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsMissingRequiredField() {
        // `member_count` omitted — every field on the wire is required.
        let json = """
            { "events": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "TEST TRIP 01",
              "start_date": null,
              "end_date": null,
              "status": "active",
              "total": 0,
              "currency": null,
              "created_at": "2026-08-18T21:40:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(EventsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyEventsAsAValidState() throws {
        let json = """
            { "events": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(EventsResponse.self, from: Data(json.utf8))
        #expect(response.events.isEmpty)
    }
}
