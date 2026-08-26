import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.spendingBars(_:)` — pure geometry, no drawing
/// framework involved. Fixtures are synthetic round amounts
/// (`.claude/rules/data-safety.md`).
///
/// No gap-fill tests here anymore: the backend gap-fills `by_bucket` itself
/// when both `start`/`end` are given (`docs/decisions/
/// 0007-dashboard-aggregation.md`'s third revision) — this function trusts
/// whatever series it is handed.
struct DailyBarsTests {
    private static func entry(
        _ day: CalendarDate, spending: Int, income: Int = 0
    ) -> BucketSummaryResponse {
        let end = CalendarDate(year: day.year, month: day.month, day: day.day + 1)
        return BucketSummaryResponse(
            start: day, end: end, spending: spending, income: income, transactionCount: 1
        )
    }

    @Test func returnsNoBarsForEmptyInput() {
        #expect(TraccioCore.spendingBars([]).isEmpty)
    }

    @Test func singleDayIsTheTallestBarAtFullFraction() {
        let day = CalendarDate(year: 2026, month: 8, day: 10)
        let bars = TraccioCore.spendingBars([Self.entry(day, spending: 3000)])
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
        let bars = TraccioCore.spendingBars(entries)
        #expect(bars.map(\.fraction) == [0.25, 1.0])
    }

    @Test func preservesInputOrderRatherThanResorting() {
        // The backend already sorts by_bucket chronologically; this function
        // must not re-sort a differently-ordered input either — same trust
        // donutSegments(_:) places in the backend's own order.
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 15), spending: 1000),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 2000),
        ]
        let bars = TraccioCore.spendingBars(entries)
        #expect(bars.map(\.day) == [
            CalendarDate(year: 2026, month: 8, day: 15),
            CalendarDate(year: 2026, month: 8, day: 10),
        ])
    }

    @Test func allZeroSpendingProducesAllZeroFractions() {
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 0, income: 500),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 11), spending: 0),
        ]
        let bars = TraccioCore.spendingBars(entries)
        #expect(bars.allSatisfy { $0.fraction == 0 })
    }

    @Test func aZeroValueGapFilledBucketProducesAZeroBar() {
        // A bucket the backend gap-filled (no transactions that day) still
        // renders as a real, zero-height bar, not skipped.
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 1000),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 11), spending: 0),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 12), spending: 2000),
        ]
        let bars = TraccioCore.spendingBars(entries)
        #expect(bars.count == 3)
        #expect(bars[1].spending == 0)
        #expect(bars[1].fraction == 0)
    }
}
