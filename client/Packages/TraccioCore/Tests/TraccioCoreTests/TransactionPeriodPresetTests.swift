import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TransactionPeriodPreset.range(calendar:now:)`. All fixed to a
/// UTC Gregorian calendar and explicit dates, mirroring `MonthPeriodTests`.
struct TransactionPeriodPresetTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: components)!
    }

    @Test func allHasNoBound() {
        let range = TransactionPeriodPreset.all.range(calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        #expect(range.start == nil)
        #expect(range.end == nil)
    }

    @Test func thisMonthMatchesTheContainingCalendarMonth() {
        let range = TransactionPeriodPreset.thisMonth.range(
            calendar: Self.utcCalendar, now: Self.date(2026, 8, 18)
        )
        #expect(range.start == Self.date(2026, 8, 1))
        #expect(range.end == Self.date(2026, 9, 1))
    }

    @Test func lastMonthStepsBackOneMonth() {
        let range = TransactionPeriodPreset.lastMonth.range(
            calendar: Self.utcCalendar, now: Self.date(2026, 8, 18)
        )
        #expect(range.start == Self.date(2026, 7, 1))
        #expect(range.end == Self.date(2026, 8, 1))
    }

    @Test func lastMonthCrossesAYearBoundary() {
        let range = TransactionPeriodPreset.lastMonth.range(
            calendar: Self.utcCalendar, now: Self.date(2026, 1, 15)
        )
        #expect(range.start == Self.date(2025, 12, 1))
        #expect(range.end == Self.date(2026, 1, 1))
    }

    @Test func last3MonthsCoversThisMonthAndTheTwoBefore() {
        let range = TransactionPeriodPreset.last3Months.range(
            calendar: Self.utcCalendar, now: Self.date(2026, 8, 18)
        )
        #expect(range.start == Self.date(2026, 6, 1))
        #expect(range.end == Self.date(2026, 9, 1))
    }

    @Test func last3MonthsCrossesAYearBoundary() {
        let range = TransactionPeriodPreset.last3Months.range(
            calendar: Self.utcCalendar, now: Self.date(2026, 1, 15)
        )
        #expect(range.start == Self.date(2025, 11, 1))
        #expect(range.end == Self.date(2026, 2, 1))
    }

    @Test func thisYearMatchesTheContainingCalendarYear() {
        let range = TransactionPeriodPreset.thisYear.range(
            calendar: Self.utcCalendar, now: Self.date(2026, 8, 18)
        )
        #expect(range.start == Self.date(2026, 1, 1))
        #expect(range.end == Self.date(2027, 1, 1))
    }
}
