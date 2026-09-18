import Foundation
import Testing

@testable import TraccioCore

/// Tests for `formatCalendarDate`/`formatCalendarDateRange`
/// (`Formatting/CalendarDateFormatter.swift`) — the only formatter in
/// `TraccioCore` with no test file of its own until this one, despite being
/// the sole place a `CalendarDate` becomes display text.
struct CalendarDateFormatterTests {
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

    @Test func fallsBackToTheWireValueForAnUnresolvableDate() {
        // `CalendarDate`'s memberwise `init` doesn't validate its components
        // (the backend never sends a malformed one, but nothing stops a
        // caller from constructing one) — `Calendar.date(from:)` normalizes
        // most out-of-range values (e.g. day 31 of February rolls into
        // March) but genuinely fails to resolve a wildly out-of-range month,
        // so the formatter falls back to the raw wire string rather than
        // crashing or silently substituting a different date.
        let date = CalendarDate(year: 2026, month: 999_999_999, day: 1)
        #expect(TraccioCore.formatCalendarDate(date) == "2026-999999999-01")
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
}
