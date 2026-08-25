import Foundation

/// One root category paired with its direct children, as produced by
/// `categoryTree(_:)`.
public struct CategoryTreeNode: Sendable, Equatable, Identifiable {
    public let category: CategoryResponse
    public let children: [CategoryResponse]

    public var id: UUID { category.id }

    public init(category: CategoryResponse, children: [CategoryResponse]) {
        self.category = category
        self.children = children
    }
}

extension TraccioCore {
    /// Group a flat category list into roots with their direct children.
    ///
    /// Pure presentation grouping, not a derivation of any value (`.claude/
    /// rules/swift.md`): `GET /categories` already returns a flat,
    /// backend-ordered list (each root immediately followed by its own
    /// children — see `traccio.db.repositories.list_categories`), and this
    /// function only reshapes it into the two-level structure a picker or a
    /// settings screen wants to render, without re-sorting either level.
    /// Depth-agnostic in its *implementation* even though the domain itself
    /// is a strict two-level hierarchy (ADR 0018): it groups purely by
    /// `parentID`, so it never assumes the input arrives pre-interleaved.
    ///
    /// Parameters
    /// ----------
    /// categories:
    ///     A flat list of categories, in any order.
    ///
    /// Returns
    /// -------
    /// One node per root (`parentID == nil`), in the order roots appear in
    /// `categories`, each carrying its children in the order they appear in
    /// `categories`. A child whose named parent is missing from `categories`
    /// (a real data inconsistency, not expected in practice) is silently
    /// excluded, rather than crashing or fabricating a placeholder root.
    public static func categoryTree(_ categories: [CategoryResponse]) -> [CategoryTreeNode] {
        var childrenByParent: [UUID: [CategoryResponse]] = [:]
        for category in categories {
            if let parentID = category.parentID {
                childrenByParent[parentID, default: []].append(category)
            }
        }
        return categories
            .filter { $0.parentID == nil }
            .map { CategoryTreeNode(category: $0, children: childrenByParent[$0.id] ?? []) }
    }
}
