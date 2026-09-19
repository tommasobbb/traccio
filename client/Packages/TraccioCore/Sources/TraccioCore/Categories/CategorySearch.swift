import Foundation

extension TraccioCore {
    /// Filter a category tree by a free-text query, for "Categorie e regole"'s
    /// search field.
    ///
    /// A root is kept when it matches (carrying *all* its children along, so
    /// a matched parent still shows its full contents) or when any child
    /// matches (carrying only the matching children — a parent search doesn't
    /// widen to siblings that don't match). Case- and diacritic-insensitive.
    /// A blank query returns `tree` unchanged, so the caller never branches
    /// on "is the user searching".
    ///
    /// Parameters
    /// ----------
    /// tree:
    ///     The category tree to filter, as `categoryTree(_:)` produces it.
    /// query:
    ///     The free-text query. Blank (after trimming) matches everything.
    ///
    /// Returns
    /// -------
    /// The filtered tree, root order and child order preserved.
    public static func filterCategoryTree(
        _ tree: [CategoryTreeNode], matching query: String
    ) -> [CategoryTreeNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tree }

        return tree.compactMap { node in
            if matches(node.category.name, trimmed) {
                return node
            }
            let matchingChildren = node.children.filter { matches($0.name, trimmed) }
            guard !matchingChildren.isEmpty else { return nil }
            return CategoryTreeNode(category: node.category, children: matchingChildren)
        }
    }

    /// Filter rules by pattern or by their resolved target-category name, for
    /// the same search field.
    ///
    /// Parameters
    /// ----------
    /// rules:
    ///     The rules to filter, in their existing (evaluation) order.
    /// query:
    ///     The free-text query. Blank (after trimming) matches everything.
    /// categoryNames:
    ///     Category id to name, for resolving each rule's target — the same
    ///     lookup the rules card already does for display. A rule whose
    ///     `categoryID` is absent (a momentarily stale list) matches on
    ///     pattern only, never crashes.
    ///
    /// Returns
    /// -------
    /// The filtered rules, order preserved.
    public static func filterRules(
        _ rules: [RuleResponse], matching query: String, categoryNames: [UUID: String]
    ) -> [RuleResponse] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rules }

        return rules.filter { rule in
            if matches(rule.pattern, trimmed) { return true }
            guard let categoryName = categoryNames[rule.categoryID] else { return false }
            return matches(categoryName, trimmed)
        }
    }

    private static func matches(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
