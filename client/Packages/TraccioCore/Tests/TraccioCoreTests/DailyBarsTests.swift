import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.dailyBars(_:)` — pure geometry, no drawing
/// framework involved. Fixtures are synthetic round amounts
/// (`.claude/rules/data-safety.md`).
struct DailyBarsTests {
    private static func entry(
        _ day: CalendarDate, spending: Int, income: Int = 0
    ) -> DaySummaryResponse {
        DaySummaryResponse(date: day, spending: spending, income: income, transactionCount: 1)
    }

    @Test func returnsNoBarsForEmptyInput() {
        #expect(TraccioCore.dailyBars([]).isEmpty)
    }

    @Test func singleDayIsTheTallestBarAtFullFraction() {
        let day = CalendarDate(year: 2026, month: 8, day: 10)
        let bars = TraccioCore.dailyBars([Self.entry(day, spending: 3000)])
        #expect(bars.count == 1)
        #expect(bars[0].day == day)
        #expect(bars[0].spending == 3000)
        #expect(bars[0].fraction == 1)
    }

    @Test func fractionsAreRelativeToTheTallestBar() {
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 1000),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 11), spending: 4000),
        ]
        let bars = TraccioCore.dailyBars(entries)
        #expect(bars.map(\.fraction) == [0.25, 1.0])
    }

    @Test func fillsAnInteriorGapWithAZeroBar() {
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 1000),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 12), spending: 2000),
        ]
        let bars = TraccioCore.dailyBars(entries)
        #expect(
            bars.map(\.day) == [
                CalendarDate(year: 2026, month: 8, day: 10),
                CalendarDate(year: 2026, month: 8, day: 11),
                CalendarDate(year: 2026, month: 8, day: 12),
            ]
        )
        #expect(bars[1].spending == 0)
        #expect(bars[1].fraction == 0)
    }

    @Test func fillsAGapAcrossAMonthBoundary() {
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 30), spending: 1000),
            Self.entry(CalendarDate(year: 2026, month: 9, day: 1), spending: 2000),
        ]
        let bars = TraccioCore.dailyBars(entries)
        #expect(
            bars.map(\.day) == [
                CalendarDate(year: 2026, month: 8, day: 30),
                CalendarDate(year: 2026, month: 8, day: 31),
                CalendarDate(year: 2026, month: 9, day: 1),
            ]
        )
    }

    @Test func allZeroSpendingProducesAllZeroFractions() {
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 0, income: 500),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 11), spending: 0),
        ]
        let bars = TraccioCore.dailyBars(entries)
        #expect(bars.allSatisfy { $0.fraction == 0 })
    }

    @Test func sortsChronologicallyRegardlessOfInputOrder() {
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 15), spending: 1000),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 2000),
        ]
        let bars = TraccioCore.dailyBars(entries)
        #expect(bars.first?.day == CalendarDate(year: 2026, month: 8, day: 10))
        #expect(bars.last?.day == CalendarDate(year: 2026, month: 8, day: 15))
    }
}
