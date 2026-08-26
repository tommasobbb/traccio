import Foundation
import Testing

@testable import TraccioCore

/// Tests for `CalendarPeriod`. All fixed to a UTC Gregorian calendar and
/// explicit dates so nothing here depends on the wall clock or the machine's
/// time zone.
struct CalendarPeriodTests {
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

    // MARK: .month (mirrors the old MonthPeriodTests)

    @Test func currentMonthResolvesToTheContainingMonth() {
        let now = Self.date(2026, 8, 18, hour: 21)
        let period = CalendarPeriod.current(unit: .month, calendar: Self.utcCalendar, now: now)

        #expect(period.start == Self.date(2026, 8, 1))
        // End is exclusive: the first instant of September, not August 31.
        #expect(period.end == Self.date(2026, 9, 1))
    }

    @Test func monthEndIsExclusiveOfTheLastDayOfTheMonth() {
        let lastMoment = Self.date(2026, 8, 31, hour: 23)
        let period = CalendarPeriod.current(unit: .month, calendar: Self.utcCalendar, now: lastMoment)

        #expect(period.end == Self.date(2026, 9, 1))
        #expect(lastMoment >= period.start)
        #expect(lastMoment < period.end)
    }

    @Test func monthPreviousStepsBackOneMonth() {
        let period = CalendarPeriod.current(unit: .month, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        let previous = period.previous()

        #expect(previous.start == Self.date(2026, 7, 1))
        #expect(previous.end == Self.date(2026, 8, 1))
    }

    @Test func monthPreviousCrossesAYearBoundary() {
        let january = CalendarPeriod.current(unit: .month, calendar: Self.utcCalendar, now: Self.date(2026, 1, 15))
        let december = january.previous()

        #expect(december.start == Self.date(2025, 12, 1))
        #expect(december.end == Self.date(2026, 1, 1))
    }

    @Test func monthNextStepsForwardOneMonthAndCrossesAYearBoundary() {
        let december = CalendarPeriod.current(unit: .month, calendar: Self.utcCalendar, now: Self.date(2025, 12, 15))
        let january = december.next()

        #expect(january.start == Self.date(2026, 1, 1))
        #expect(january.end == Self.date(2026, 2, 1))
    }

    @Test func monthNextAndPreviousAreInverses() {
        let period = CalendarPeriod.current(unit: .month, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        #expect(period.next().previous() == period)
    }

    // MARK: .quarter

    @Test func currentQuarterResolvesToTheContainingQuarter() {
        // August is in Q3 (Jul-Sep).
        let period = CalendarPeriod.current(unit: .quarter, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))

        #expect(period.start == Self.date(2026, 7, 1))
        #expect(period.end == Self.date(2026, 10, 1))
    }

    @Test func firstMonthOfAQuarterResolvesToTheSameQuarter() {
        let period = CalendarPeriod.current(unit: .quarter, calendar: Self.utcCalendar, now: Self.date(2026, 7, 1))
        #expect(period.start == Self.date(2026, 7, 1))
        #expect(period.end == Self.date(2026, 10, 1))
    }

    @Test func lastMonthOfAQuarterResolvesToTheSameQuarter() {
        let period = CalendarPeriod.current(unit: .quarter, calendar: Self.utcCalendar, now: Self.date(2026, 9, 30))
        #expect(period.start == Self.date(2026, 7, 1))
        #expect(period.end == Self.date(2026, 10, 1))
    }

    @Test func quarterPreviousCrossesAYearBoundary() {
        // Q1 2026 (Jan-Mar) steps back to Q4 2025 (Oct-Dec).
        let q1 = CalendarPeriod.current(unit: .quarter, calendar: Self.utcCalendar, now: Self.date(2026, 2, 10))
        let q4Prior = q1.previous()

        #expect(q4Prior.start == Self.date(2025, 10, 1))
        #expect(q4Prior.end == Self.date(2026, 1, 1))
    }

    @Test func quarterNextAndPreviousAreInverses() {
        let period = CalendarPeriod.current(unit: .quarter, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        #expect(period.next().previous() == period)
    }

    // MARK: .year

    @Test func currentYearResolvesToTheContainingYear() {
        let period = CalendarPeriod.current(unit: .year, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))

        #expect(period.start == Self.date(2026, 1, 1))
        #expect(period.end == Self.date(2027, 1, 1))
    }

    @Test func yearPreviousStepsBackOneYear() {
        let period = CalendarPeriod.current(unit: .year, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        let previous = period.previous()

        #expect(previous.start == Self.date(2025, 1, 1))
        #expect(previous.end == Self.date(2026, 1, 1))
    }

    @Test func yearNextAndPreviousAreInverses() {
        let period = CalendarPeriod.current(unit: .year, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
        #expect(period.next().previous() == period)
    }

    // MARK: granularity

    @Test func granularityMapsEachUnitToItsBucketSize() {
        #expect(
            CalendarPeriod.current(unit: .month, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
                .granularity == .day
        )
        #expect(
            CalendarPeriod.current(unit: .quarter, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
                .granularity == .week
        )
        #expect(
            CalendarPeriod.current(unit: .year, calendar: Self.utcCalendar, now: Self.date(2026, 8, 18))
                .granularity == .month
        )
    }
}
