import Foundation
import Testing

@testable import TraccioCore

/// Tests for `CalendarDate` — the date-only value type for
/// `EventResponse.start_date`/`end_date`, which serialise as `"yyyy-MM-dd"`,
/// not a full ISO 8601 date-time.
struct CalendarDateTests {
    @Test func decodesAWireDate() throws {
        let json = "\"2026-08-01\""
        let decoded = try TraccioCore.jsonDecoder().decode(CalendarDate.self, from: Data(json.utf8))
        #expect(decoded == CalendarDate(year: 2026, month: 8, day: 1))
    }

    @Test func encodesBackToTheSameWireShape() throws {
        let date = CalendarDate(year: 2026, month: 3, day: 9)
        let encoded = try TraccioCore.jsonEncoder().encode(date)
        #expect(String(data: encoded, encoding: .utf8) == "\"2026-03-09\"")
    }

    @Test func roundTripsThroughEncodeAndDecode() throws {
        let date = CalendarDate(year: 2025, month: 12, day: 31)
        let encoded = try TraccioCore.jsonEncoder().encode(date)
        let decoded = try TraccioCore.jsonDecoder().decode(CalendarDate.self, from: encoded)
        #expect(decoded == date)
    }

    @Test func ordersByYearThenMonthThenDay() {
        #expect(
            CalendarDate(year: 2026, month: 1, day: 1) < CalendarDate(year: 2026, month: 1, day: 2)
        )
        #expect(
            CalendarDate(year: 2026, month: 1, day: 31) < CalendarDate(year: 2026, month: 2, day: 1)
        )
        #expect(
            CalendarDate(year: 2025, month: 12, day: 31) < CalendarDate(year: 2026, month: 1, day: 1)
        )
    }

    @Test func rejectsAnUnpaddedDate() {
        let json = "\"2026-8-1\""
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(CalendarDate.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsAFullDateTimeString() {
        // A date-*time* must not silently decode as a calendar date, dropping
        // the time component the caller actually sent.
        let json = "\"2026-08-01T00:00:00Z\""
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(CalendarDate.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsNonNumericComponents() {
        let json = "\"non è una data\""
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(CalendarDate.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsAnOutOfRangeMonth() {
        let json = "\"2026-13-01\""
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(CalendarDate.self, from: Data(json.utf8))
        }
    }

    @Test func extractsComponentsFromADateInUTC() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 1
        components.hour = 23  // Deliberately late in the day, still the 1st in UTC.
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let extracted = CalendarDate(date: date)
        #expect(extracted == CalendarDate(year: 2026, month: 8, day: 1))
    }

    @Test func formatsWithAFixedLocale() {
        let date = CalendarDate(year: 2026, month: 8, day: 1)
        let formatted = TraccioCore.formatCalendarDate(date, locale: Locale(identifier: "en_US_POSIX"))
        #expect(formatted.contains("2026"))
        #expect(formatted.contains("1") || formatted.contains("01"))
    }
}
