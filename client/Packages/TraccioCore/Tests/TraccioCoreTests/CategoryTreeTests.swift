import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.categoryTree(_:)` — pure grouping logic, no backend
/// involved. Fixtures are synthetic (`.claude/rules/data-safety.md`):
/// invented names, round dates.
struct CategoryTreeTests {
    private static func category(
        id: UUID = UUID(), name: String, parentID: UUID? = nil, color: PaletteColor = .slate
    ) -> CategoryResponse {
        CategoryResponse(
            id: id, name: name, parentID: parentID, color: color, icon: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func groupsEachRootWithItsChildren() {
        let housing = Self.category(name: "Casa")
        let rent = Self.category(name: "Affitto", parentID: housing.id)
        let maintenance = Self.category(name: "Manutenzione", parentID: housing.id)
        let groceries = Self.category(name: "Alimentari")

        let tree = TraccioCore.categoryTree([housing, rent, groceries, maintenance])

        #expect(tree.map(\.category.id) == [housing.id, groceries.id])
        #expect(tree[0].children.map(\.id) == [rent.id, maintenance.id])
        #expect(tree[1].children.isEmpty)
    }

    @Test func rootWithNoChildrenHasAnEmptyChildrenArray() {
        let root = Self.category(name: "Alimentari")

        let tree = TraccioCore.categoryTree([root])

        #expect(tree.count == 1)
        #expect(tree[0].children.isEmpty)
    }

    @Test func emptyInputProducesEmptyOutput() {
        #expect(TraccioCore.categoryTree([]).isEmpty)
    }

    @Test func aChildWhoseParentIsMissingIsExcluded() {
        // A real data inconsistency: the parent named by parentID never
        // appears in the input. The orphaned child is dropped, not crashed
        // on or promoted to a root it never claimed to be.
        let orphan = Self.category(name: "Affitto", parentID: UUID())
        let root = Self.category(name: "Alimentari")

        let tree = TraccioCore.categoryTree([orphan, root])

        #expect(tree.map(\.category.id) == [root.id])
    }

    @Test func preservesInputOrderForBothRootsAndChildren() {
        let transport = Self.category(name: "Trasporti")
        let housing = Self.category(name: "Casa")
        let fuel = Self.category(name: "Benzina", parentID: transport.id)
        let publicTransport = Self.category(name: "Mezzi pubblici", parentID: transport.id)

        // Deliberately not pre-sorted or interleaved — categoryTree groups by
        // parentID alone, it does not assume backend ordering.
        let tree = TraccioCore.categoryTree([transport, fuel, housing, publicTransport])

        #expect(tree.map(\.category.id) == [transport.id, housing.id])
        #expect(tree[0].children.map(\.id) == [fuel.id, publicTransport.id])
    }
}
