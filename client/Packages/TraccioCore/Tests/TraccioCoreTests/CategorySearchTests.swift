import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.filterCategoryTree(_:matching:)` and
/// `filterRules(_:matching:categoryNames:)` — pure filtering, no backend
/// involved. Fixtures are synthetic (`docs/engineering.md`): invented names,
/// round dates.
struct CategorySearchTests {
    private static func category(
        id: UUID = UUID(), name: String, parentID: UUID? = nil, color: PaletteColor = .slate
    ) -> CategoryResponse {
        CategoryResponse(
            id: id, name: name, parentID: parentID, color: color, icon: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func rule(
        id: UUID = UUID(), categoryID: UUID, matchKind: RuleMatchKind = .contains, pattern: String
    ) -> RuleResponse {
        RuleResponse(
            id: id, categoryID: categoryID, matchKind: matchKind, pattern: pattern,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: filterCategoryTree

    @Test func blankQueryReturnsTheTreeUnchanged() {
        let root = Self.category(name: "Alimentari")
        let tree = TraccioCore.categoryTree([root])

        #expect(TraccioCore.filterCategoryTree(tree, matching: "   ") == tree)
    }

    @Test func rootMatchKeepsAllItsChildren() {
        let housing = Self.category(name: "Casa")
        let rent = Self.category(name: "Affitto", parentID: housing.id)
        let maintenance = Self.category(name: "Manutenzione", parentID: housing.id)
        let groceries = Self.category(name: "Alimentari")
        let tree = TraccioCore.categoryTree([housing, rent, groceries, maintenance])

        let filtered = TraccioCore.filterCategoryTree(tree, matching: "Casa")

        #expect(filtered.map(\.category.id) == [housing.id])
        #expect(filtered[0].children.map(\.id) == [rent.id, maintenance.id])
    }

    @Test func childMatchKeepsOnlyThatChildUnderItsRoot() {
        let housing = Self.category(name: "Casa")
        let rent = Self.category(name: "Affitto", parentID: housing.id)
        let maintenance = Self.category(name: "Manutenzione", parentID: housing.id)
        let tree = TraccioCore.categoryTree([housing, rent, maintenance])

        let filtered = TraccioCore.filterCategoryTree(tree, matching: "affitto")

        #expect(filtered.map(\.category.id) == [housing.id])
        #expect(filtered[0].children.map(\.id) == [rent.id])
    }

    @Test func caseAndDiacriticInsensitive() {
        let root = Self.category(name: "Caffè")
        let tree = TraccioCore.categoryTree([root])

        #expect(TraccioCore.filterCategoryTree(tree, matching: "CAFFE").map(\.category.id) == [root.id])
    }

    @Test func noMatchProducesAnEmptyArray() {
        let root = Self.category(name: "Alimentari")
        let tree = TraccioCore.categoryTree([root])

        #expect(TraccioCore.filterCategoryTree(tree, matching: "Trasporti").isEmpty)
    }

    // MARK: filterRules

    @Test func filterRulesBlankQueryReturnsAllRules() {
        let groceries = UUID()
        let rules = [Self.rule(categoryID: groceries, pattern: "TEST MERCHANT 01")]

        #expect(TraccioCore.filterRules(rules, matching: "", categoryNames: [:]) == rules)
    }

    @Test func filterRulesMatchesOnPattern() {
        let groceries = UUID()
        let matching = Self.rule(categoryID: groceries, pattern: "TEST MERCHANT 01")
        let other = Self.rule(categoryID: groceries, pattern: "TEST SUBSCRIPTION")
        let rules = [matching, other]

        let filtered = TraccioCore.filterRules(rules, matching: "merchant", categoryNames: [:])

        #expect(filtered.map(\.id) == [matching.id])
    }

    @Test func filterRulesMatchesOnResolvedCategoryName() {
        let groceries = UUID()
        let rule = Self.rule(categoryID: groceries, pattern: "TEST MERCHANT 01")

        let filtered = TraccioCore.filterRules(
            [rule], matching: "alimentari", categoryNames: [groceries: "Alimentari"]
        )

        #expect(filtered.map(\.id) == [rule.id])
    }

    @Test func filterRulesWithAnUnresolvedCategoryMatchesOnPatternOnlyAndDoesNotCrash() {
        let groceries = UUID()
        let rule = Self.rule(categoryID: groceries, pattern: "TEST MERCHANT 01")

        // categoryNames deliberately omits `groceries` — a momentarily stale
        // category list should degrade to pattern-only matching, not crash.
        #expect(
            TraccioCore.filterRules([rule], matching: "merchant", categoryNames: [:]).map(\.id) == [rule.id]
        )
        #expect(TraccioCore.filterRules([rule], matching: "alimentari", categoryNames: [:]).isEmpty)
    }
}
