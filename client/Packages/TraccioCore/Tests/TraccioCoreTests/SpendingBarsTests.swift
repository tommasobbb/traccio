import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.spendingBars(_:)` — pure geometry, no drawing
/// framework involved. Fixtures are synthetic round amounts
/// (`docs/engineering.md`).
///
/// No gap-fill tests here: the backend gap-fills `by_bucket` itself when
/// both `start`/`end` are given (`docs/decisions/
/// 0007-dashboard-aggregation.md`'s third revision) — this function trusts
/// whatever series it is handed.
struct SpendingBarsTests {
    private static func entry(
        _ start: CalendarDate, spending: Int, transactionCount: Int = 1
    ) -> BucketSummaryResponse {
        let end = CalendarDate(year: start.year, month: start.month, day: start.day + 1)
        return BucketSummaryResponse(
            start: start, end: end, spending: spending, income: 0, transactionCount: transactionCount
        )
    }

    @Test func returnsNoBarsForEmptyInput() {
        #expect(TraccioCore.spendingBars([]).isEmpty)
    }

    @Test func singleBarIsTheTallestBarAtFullFraction() {
        let start = CalendarDate(year: 2026, month: 8, day: 10)
        let bars = TraccioCore.spendingBars([Self.entry(start, spending: 3000)])
        #expect(bars.count == 1)
        #expect(bars[0].start == start)
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
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 15), spending: 1000),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 2000),
        ]
        let bars = TraccioCore.spendingBars(entries)
        #expect(
            bars.map(\.start) == [
                CalendarDate(year: 2026, month: 8, day: 15),
                CalendarDate(year: 2026, month: 8, day: 10),
            ]
        )
    }

    @Test func allZeroSpendingProducesAllZeroFractions() {
        let entries = [
            Self.entry(CalendarDate(year: 2026, month: 8, day: 10), spending: 0),
            Self.entry(CalendarDate(year: 2026, month: 8, day: 11), spending: 0),
        ]
        let bars = TraccioCore.spendingBars(entries)
        #expect(bars.allSatisfy { $0.fraction == 0 })
    }

    @Test func aZeroValueGapFilledBucketProducesAZeroBar() {
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

    @Test func carriesEndAndTransactionCountForTheTooltip() {
        let start = CalendarDate(year: 2026, month: 8, day: 10)
        let end = CalendarDate(year: 2026, month: 8, day: 17)  // a week bucket
        let entry = BucketSummaryResponse(
            start: start, end: end, spending: 5000, income: 0, transactionCount: 7
        )
        let bars = TraccioCore.spendingBars([entry])
        #expect(bars[0].end == end)
        #expect(bars[0].transactionCount == 7)
    }
}
