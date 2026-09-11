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
        #expect(formatted == "Aug 1, 2026")
    }

    @Test func formatsInItalianByDefault() {
        // Regression test: `formatCalendarDate` used to force an `.iso8601`
        // calendar onto the `DateFormatter` while leaving `locale` at
        // `.current`, which made it fall back to that calendar's own
        // year-first, English month symbols (`"2026 Sep 10"`) regardless of
        // the requested locale — a loose `contains("2026")` assertion here
        // would not have caught it.
        let date = CalendarDate(year: 2026, month: 9, day: 10)
        #expect(TraccioCore.formatCalendarDate(date) == "10 set 2026")
    }

    // MARK: formatCalendarDateRange

    @Test func rangeCollapsesToASingleDateWhenEndIsNil() {
        let start = CalendarDate(year: 2026, month: 9, day: 10)
        #expect(TraccioCore.formatCalendarDateRange(from: start, to: nil) == "10 set 2026")
    }

    @Test func rangeCollapsesToASingleDateWhenEndEqualsStart() {
        let day = CalendarDate(year: 2026, month: 9, day: 10)
        #expect(TraccioCore.formatCalendarDateRange(from: day, to: day) == "10 set 2026")
    }

    @Test func rangeWithinTheSameMonthShowsOnlyTheEndingDayAndMonth() {
        let start = CalendarDate(year: 2026, month: 9, day: 10)
        let end = CalendarDate(year: 2026, month: 9, day: 12)
        #expect(TraccioCore.formatCalendarDateRange(from: start, to: end) == "10 – 12 set 2026")
    }

    @Test func rangeAcrossMonthsWithinTheSameYearOmitsTheStartYear() {
        let start = CalendarDate(year: 2026, month: 9, day: 28)
        let end = CalendarDate(year: 2026, month: 10, day: 3)
        #expect(TraccioCore.formatCalendarDateRange(from: start, to: end) == "28 set – 3 ott 2026")
    }

    @Test func rangeAcrossYearsSpellsOutBothDatesInFull() {
        let start = CalendarDate(year: 2025, month: 12, day: 28)
        let end = CalendarDate(year: 2026, month: 1, day: 3)
        #expect(TraccioCore.formatCalendarDateRange(from: start, to: end) == "28 dic 2025 – 3 gen 2026")
    }

    // MARK: date(calendar:)

    @Test func dateReconstructsMidnightInTheGivenCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let calendarDate = CalendarDate(year: 2026, month: 8, day: 10)

        let reconstructed = calendarDate.date(calendar: calendar)

        #expect(reconstructed != nil)
        #expect(CalendarDate(date: reconstructed!, calendar: calendar) == calendarDate)
    }

    @Test func dateRoundTripsThroughInitDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 10
        components.hour = 12
        let original = calendar.date(from: components)!

        let calendarDate = CalendarDate(date: original, calendar: calendar)
        let reconstructed = calendarDate.date(calendar: calendar)

        #expect(reconstructed != nil)
        #expect(CalendarDate(date: reconstructed!, calendar: calendar) == calendarDate)
    }
}
