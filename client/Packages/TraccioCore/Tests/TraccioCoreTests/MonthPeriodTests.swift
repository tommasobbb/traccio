import Foundation
import Testing

@testable import TraccioCore

/// Tests for `MonthPeriod`. All fixed to a UTC Gregorian calendar and
/// explicit dates so nothing here depends on the wall clock or the machine's
/// time zone.
struct MonthPeriodTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: components)!
    }

    @Test func currentResolvesToTheContainingMonth() {
        let now = Self.date(2026, 8, 18, hour: 21)
        let period = MonthPeriod.current(calendar: Self.utcCalendar, now: now)

        #expect(period.start == Self.date(2026, 8, 1))
        // End is exclusive: the first instant of September, not August 31.
        #expect(period.end == Self.date(2026, 9, 1))
    }

    @Test func endIsExclusiveOfTheLastDayOfTheMonth() {
        let lastMoment = Self.date(2026, 8, 31, hour: 23)
        let period = MonthPeriod.current(calendar: Self.utcCalendar, now: lastMoment)

        #expect(period.end == Self.date(2026, 9, 1))
        // The last instant of the month is still inside [start, end).
        #expect(lastMoment >= period.start)
        #expect(lastMoment < period.end)
    }

    @Test func previousStepsBackOneMonth() {
        let period = MonthPeriod.current(calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        let previous = period.previous()

        #expect(previous.start == Self.date(2026, 7, 1))
        #expect(previous.end == Self.date(2026, 8, 1))
    }

    @Test func previousCrossesAYearBoundary() {
        let january = MonthPeriod.current(calendar: Self.utcCalendar, now: Self.date(2026, 1, 15))
        let december = january.previous()

        #expect(december.start == Self.date(2025, 12, 1))
        #expect(december.end == Self.date(2026, 1, 1))
    }

    @Test func nextStepsForwardOneMonthAndCrossesAYearBoundary() {
        let december = MonthPeriod.current(calendar: Self.utcCalendar, now: Self.date(2025, 12, 15))
        let january = december.next()

        #expect(january.start == Self.date(2026, 1, 1))
        #expect(january.end == Self.date(2026, 2, 1))
    }

    @Test func nextAndPreviousAreInverses() {
        let period = MonthPeriod.current(calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        #expect(period.next().previous() == period)
    }
}
