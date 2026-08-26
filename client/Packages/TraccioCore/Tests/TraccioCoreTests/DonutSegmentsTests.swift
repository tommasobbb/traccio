import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.donutSegments(_:)` — pure geometry, no drawing
/// framework involved. Fixtures are synthetic round amounts
/// (`.claude/rules/data-safety.md`).
struct DonutSegmentsTests {
    private static func entry(
        categoryID: UUID? = nil,
        categoryName: String? = nil,
        spending: Int,
        income: Int = 0,
        transactionCount: Int = 1
    ) -> CategoryGroupSummaryResponse {
        CategoryGroupSummaryResponse(
            categoryID: categoryID,
            categoryName: categoryName,
            color: nil,
            icon: nil,
            spending: spending,
            income: income,
            transactionCount: transactionCount,
            directSpending: spending,
            directIncome: income,
            directTransactionCount: transactionCount
        )
    }

    @Test func returnsNoSegmentsForEmptyInput() {
        #expect(TraccioCore.donutSegments([]).isEmpty)
    }

    @Test func returnsNoSegmentsWhenEveryEntryIsIncomeOnly() {
        // A currency that was all income this period (spending == 0
        // everywhere) has nothing for a spending donut to show.
        let entries = [Self.entry(spending: 0, income: 5000)]
        #expect(TraccioCore.donutSegments(entries).isEmpty)
    }

    @Test func oneEntryCoversTheWholeCircle() {
        let entries = [Self.entry(spending: 5000)]
        let segments = TraccioCore.donutSegments(entries)
        #expect(segments.count == 1)
        #expect(segments[0].startFraction == 0)
        #expect(segments[0].endFraction == 1)
        #expect(segments[0].rank == 0)
    }

    @Test func fractionsAreProportionalAndCoverTheCircleWithNoGaps() {
        let a = UUID()
        let b = UUID()
        let entries = [
            Self.entry(categoryID: a, spending: 3000),
            Self.entry(categoryID: b, spending: 1000),
        ]
        let segments = TraccioCore.donutSegments(entries)
        #expect(segments.count == 2)
        #expect(segments[0].categoryID == a)
        #expect(segments[0].startFraction == 0)
        #expect(segments[0].endFraction == 0.75)
        #expect(segments[1].categoryID == b)
        #expect(segments[1].startFraction == 0.75)
        #expect(segments[1].endFraction == 1)
    }

    @Test func rankSkipsIncomeOnlyEntriesRatherThanLeavingAGap() {
        // The middle entry contributes no arc, so the third entry's rank is
        // 1, not 2 — rank tracks position among segments actually drawn.
        let first = UUID()
        let third = UUID()
        let entries = [
            Self.entry(categoryID: first, spending: 4000),
            Self.entry(categoryID: UUID(), spending: 0, income: 1000),
            Self.entry(categoryID: third, spending: 1000),
        ]
        let segments = TraccioCore.donutSegments(entries)
        #expect(segments.count == 2)
        #expect(segments[0].categoryID == first)
        #expect(segments[0].rank == 0)
        #expect(segments[1].categoryID == third)
        #expect(segments[1].rank == 1)
    }

    @Test func preservesInputOrderRatherThanResorting() {
        // The backend already sorts by_category by spending descending;
        // this function must not re-sort a differently-ordered input either
        // — it trusts the caller's order.
        let smaller = UUID()
        let bigger = UUID()
        let entries = [
            Self.entry(categoryID: smaller, spending: 1000),
            Self.entry(categoryID: bigger, spending: 3000),
        ]
        let segments = TraccioCore.donutSegments(entries)
        #expect(segments.map(\DonutSegment.categoryID) == [smaller, bigger])
    }

    @Test func theNoCategoryBucketProducesASegmentLikeAnyOther() {
        let entries = [Self.entry(categoryID: nil, spending: 2000)]
        let segments = TraccioCore.donutSegments(entries)
        #expect(segments.count == 1)
        #expect(segments[0].categoryID == nil)
    }

    @Test func aRootsSpendingAlreadyIncludesItsChildrenSoNoDoubleCounting() {
        // A root with children only draws one arc for the whole rollup — the
        // children are never drawn separately (they'd double-count).
        let root = UUID()
        let child = CategorySummaryResponse(
            categoryID: UUID(), categoryName: "Coffee", color: nil, icon: nil, spending: 2000,
            income: 0, transactionCount: 1
        )
        let entries = [
            CategoryGroupSummaryResponse(
                categoryID: root, categoryName: "Dining out", color: nil, icon: nil, spending: 5000,
                income: 0, transactionCount: 2, directSpending: 3000, directIncome: 0,
                directTransactionCount: 1, children: [child]
            )
        ]
        let segments = TraccioCore.donutSegments(entries)
        #expect(segments.count == 1)
        #expect(segments[0].categoryID == root)
        #expect(segments[0].startFraction == 0)
        #expect(segments[0].endFraction == 1)
    }
}
