import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.breakdownRows(groups:expanded:)` — pure flattening
/// of a hierarchical `by_category` into a list a `ForEach` can render.
/// Fixtures are synthetic round amounts (`docs/engineering.md`).
struct CategoryBreakdownRowsTests {
    private static func child(
        id: UUID = UUID(), name: String = "Coffee", spending: Int, transactionCount: Int = 1
    ) -> CategorySummaryResponse {
        CategorySummaryResponse(
            categoryID: id, categoryName: name, color: .orange, icon: .coffee, spending: spending,
            income: 0, transactionCount: transactionCount
        )
    }

    private static func group(
        id: UUID? = UUID(), name: String? = "Dining out", spending: Int, directSpending: Int,
        directTransactionCount: Int = 1, children: [CategorySummaryResponse] = []
    ) -> CategoryGroupSummaryResponse {
        let childCount = children.reduce(0) { $0 + $1.transactionCount }
        return CategoryGroupSummaryResponse(
            categoryID: id, categoryName: name, color: .orange, icon: .dining, spending: spending,
            income: 0, transactionCount: directTransactionCount + childCount,
            directSpending: directSpending, directIncome: 0,
            directTransactionCount: directTransactionCount, children: children
        )
    }

    @Test func returnsNoRowsForEmptyInput() {
        #expect(TraccioCore.breakdownRows(groups: [], expanded: []).isEmpty)
    }

    @Test func aZeroSpendingGroupIsExcluded() {
        let zero = Self.group(spending: 0, directSpending: 0)
        #expect(TraccioCore.breakdownRows(groups: [zero], expanded: []).isEmpty)
    }

    @Test func aCollapsedRootProducesOnlyItsOwnRow() {
        let root = UUID()
        let coffee = Self.child(spending: 2000)
        let group = Self.group(id: root, spending: 5000, directSpending: 3000, children: [coffee])

        let rows = TraccioCore.breakdownRows(groups: [group], expanded: [])

        #expect(rows.count == 1)
        #expect(rows[0].depth == 0)
        #expect(rows[0].categoryID == root)
        #expect(rows[0].amount == 5000)
        #expect(rows[0].hasChildren)
    }

    @Test func anExpandedRootAddsTheRemainderRowThenEachChild() {
        let root = UUID()
        let coffee = Self.child(name: "Coffee", spending: 2000)
        let group = Self.group(id: root, spending: 5000, directSpending: 3000, children: [coffee])

        let rows = TraccioCore.breakdownRows(groups: [group], expanded: [root])

        #expect(rows.count == 3)
        #expect(rows[0].depth == 0)
        #expect(rows[1].depth == 1)
        #expect(rows[1].isDirectRemainder)
        #expect(rows[1].amount == 3000)
        #expect(rows[1].categoryID == root)  // the remainder row still names its root
        #expect(rows[2].depth == 1)
        #expect(!rows[2].isDirectRemainder)
        #expect(rows[2].categoryID == coffee.categoryID)
        #expect(rows[2].amount == 2000)
    }

    @Test func theRemainderRowIsAbsentWhenDirectSpendingIsZero() {
        // A root spent on only via its children — nothing of its "own" to
        // show as a remainder row.
        let root = UUID()
        let coffee = Self.child(spending: 2000)
        let group = Self.group(id: root, spending: 2000, directSpending: 0, children: [coffee])

        let rows = TraccioCore.breakdownRows(groups: [group], expanded: [root])

        #expect(rows.count == 2)  // root + the one child, no remainder row
        #expect(rows.allSatisfy { !$0.isDirectRemainder })
    }

    @Test func aChildWithZeroSpendingIsExcludedFromTheExpandedList() {
        let root = UUID()
        let spentChild = Self.child(name: "Coffee", spending: 2000)
        let zeroChild = Self.child(name: "Takeout", spending: 0)
        let group = Self.group(
            id: root, spending: 5000, directSpending: 3000, children: [spentChild, zeroChild]
        )

        let rows = TraccioCore.breakdownRows(groups: [group], expanded: [root])

        // root + remainder + only the spending child.
        #expect(rows.count == 3)
        #expect(rows.map(\.categoryID).contains(zeroChild.categoryID) == false)
    }

    @Test func theNoCategoryRootNeverExpandsEvenIfSomehowInTheSet() {
        // There is no UUID to put in `expanded` for the "no category" root,
        // so it can never actually appear there — this asserts the row
        // itself carries no children regardless.
        let group = Self.group(id: nil, name: nil, spending: 1000, directSpending: 1000)
        let rows = TraccioCore.breakdownRows(groups: [group], expanded: [])
        #expect(rows.count == 1)
        #expect(rows[0].categoryID == nil)
        #expect(rows[0].name == nil)
        #expect(!rows[0].hasChildren)
    }

    @Test func preservesTheBackendsOwnOrderAcrossRoots() {
        let biggest = Self.group(name: "Housing", spending: 9000, directSpending: 9000)
        let smallest = Self.group(name: "Fees", spending: 1000, directSpending: 1000)
        let rows = TraccioCore.breakdownRows(groups: [biggest, smallest], expanded: [])
        #expect(rows.map(\.name) == ["Housing", "Fees"])
    }

    @Test func fillFractionIsRelativeToTheLargestVisibleRow() {
        let biggest = Self.group(name: "Housing", spending: 4000, directSpending: 4000)
        let smallest = Self.group(name: "Fees", spending: 1000, directSpending: 1000)
        let rows = TraccioCore.breakdownRows(groups: [biggest, smallest], expanded: [])
        #expect(rows[0].fillFraction == 1.0)
        #expect(rows[1].fillFraction == 0.25)
    }

    @Test func aChildInheritsItsRootsColorWhenUnset() {
        let root = UUID()
        let childID = UUID()
        let uncoloredChild = CategorySummaryResponse(
            categoryID: childID, categoryName: "Coffee", color: nil, icon: nil, spending: 2000,
            income: 0, transactionCount: 1
        )
        let group = Self.group(id: root, spending: 2000, directSpending: 0, children: [uncoloredChild])
        let rows = TraccioCore.breakdownRows(groups: [group], expanded: [root])
        #expect(rows[1].color == .orange)  // the root's own color
    }
}
