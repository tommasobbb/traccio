import Foundation

/// One row of the "Per categoria" breakdown list, as produced by
/// `breakdownRows(groups:expanded:)`.
///
/// Flattens a currency's hierarchical `by_category` (`CategoryGroupSummaryResponse`
/// roots with rolled-up `CategorySummaryResponse` children) into a single list a
/// `ForEach` can render directly, given which roots are currently expanded.
/// `name`/`color`/`icon` come straight from the backend's own display join
/// (`api/schemas/dashboard.py`'s `CategoryDisplay`) — this is presentation
/// *structure*, not presentation *copy*: `name` stays `nil` for the "no
/// category" bucket rather than this type inventing the Italian fallback
/// text itself (`client/CLAUDE.md`: display copy belongs in the view layer).
public struct CategoryBreakdownRow: Sendable, Equatable, Identifiable {
    /// Stable across a re-render for the same logical row — `"root:<uuid>"`,
    /// `"root:none"` (the "no category" bucket), `"direct:<uuid>"` (a root's
    /// own direct-spending remainder row), or `"child:<uuid>"`.
    public let id: String
    /// `0` for a root, `1` for a child or a direct-spending remainder row —
    /// ADR 0018's hierarchy is exactly two levels, so this never exceeds `1`.
    public let depth: Int
    /// The category this row represents — the root's id, a child's id, or
    /// (for a direct-spending remainder row) the root's own id again. `nil`
    /// only for the root "no category" bucket.
    public let categoryID: UUID?
    /// The category's current name, or `nil` for the "no category" bucket or
    /// the rare delete-race the backend's own display join already tolerates.
    public let name: String?
    public let color: PaletteColor
    public let icon: CategoryIcon?
    /// Spending in this row, minor units, a positive magnitude — a root's
    /// rollup, a child's own total, or a root's `direct_spending` for a
    /// remainder row.
    public let amount: Int
    /// This row's bar length relative to the largest `amount` among the rows
    /// `breakdownRows(groups:expanded:)` returned alongside it — a layout
    /// ratio between two backend-supplied integers, not a financial
    /// derivation, same class of computation as `DonutSegment.startFraction`.
    public let fillFraction: Double
    public let transactionCount: Int
    /// Whether this row has a chevron at all — `true` only for a root with
    /// at least one child row to expand.
    public let hasChildren: Bool
    /// Whether this is the synthetic child-depth row representing a root's
    /// own `direct_spending` — distinct from any of its literal children.
    public let isDirectRemainder: Bool

    public init(
        id: String, depth: Int, categoryID: UUID?, name: String?, color: PaletteColor,
        icon: CategoryIcon?, amount: Int, fillFraction: Double, transactionCount: Int,
        hasChildren: Bool, isDirectRemainder: Bool
    ) {
        self.id = id
        self.depth = depth
        self.categoryID = categoryID
        self.name = name
        self.color = color
        self.icon = icon
        self.amount = amount
        self.fillFraction = fillFraction
        self.transactionCount = transactionCount
        self.hasChildren = hasChildren
        self.isDirectRemainder = isDirectRemainder
    }
}

extension TraccioCore {
    /// Flatten a currency's `by_category` into a list of rows, given which
    /// roots are currently expanded.
    ///
    /// A root with zero spending is excluded entirely (nothing for the list
    /// to show) — same filter `donutSegments(_:)` applies. A collapsed root
    /// contributes only its own row; an expanded root also contributes its
    /// direct-spending remainder row (only when `direct_spending > 0` — a
    /// root with only children has nothing of its own to show as "direct"),
    /// then each child with positive spending, in the backend's own order.
    ///
    /// Parameters
    /// ----------
    /// groups:
    ///     One currency's `byCategory` list, in the order the backend
    ///     returned it.
    /// expanded:
    ///     Root category ids currently expanded. The "no category" root can
    ///     never expand (it has no children), regardless of this set's
    ///     contents.
    ///
    /// Returns
    /// -------
    /// One row per root (plus, for each expanded root, its remainder and
    /// child rows), in the backend's own order — never re-sorted here.
    public static func breakdownRows(
        groups: [CategoryGroupSummaryResponse], expanded: Set<UUID>
    ) -> [CategoryBreakdownRow] {
        struct Draft {
            let depth: Int
            let categoryID: UUID?
            let name: String?
            let color: PaletteColor
            let icon: CategoryIcon?
            let amount: Int
            let transactionCount: Int
            let hasChildren: Bool
            let isDirectRemainder: Bool
        }

        var drafts: [Draft] = []
        for group in groups where group.spending > 0 {
            let rootID = group.categoryID
            let rootColor = group.color ?? .slate
            drafts.append(
                Draft(
                    depth: 0, categoryID: rootID, name: group.categoryName, color: rootColor,
                    icon: group.icon, amount: group.spending, transactionCount: group.transactionCount,
                    hasChildren: !group.children.isEmpty, isDirectRemainder: false
                )
            )
            guard let rootID, expanded.contains(rootID) else { continue }
            if group.directSpending > 0 {
                drafts.append(
                    Draft(
                        depth: 1, categoryID: rootID, name: group.categoryName, color: rootColor,
                        icon: group.icon, amount: group.directSpending,
                        transactionCount: group.directTransactionCount, hasChildren: false,
                        isDirectRemainder: true
                    )
                )
            }
            for child in group.children where child.spending > 0 {
                drafts.append(
                    Draft(
                        depth: 1, categoryID: child.categoryID, name: child.categoryName,
                        color: child.color ?? rootColor, icon: child.icon, amount: child.spending,
                        transactionCount: child.transactionCount, hasChildren: false,
                        isDirectRemainder: false
                    )
                )
            }
        }

        let maxAmount = drafts.map(\.amount).max() ?? 0
        return drafts.map { draft in
            let fraction = maxAmount > 0 ? Double(draft.amount) / Double(maxAmount) : 0
            let idPrefix = draft.isDirectRemainder ? "direct" : (draft.depth == 0 ? "root" : "child")
            let idSuffix = draft.categoryID?.uuidString ?? "none"
            return CategoryBreakdownRow(
                id: "\(idPrefix):\(idSuffix)",
                depth: draft.depth,
                categoryID: draft.categoryID,
                name: draft.name,
                color: draft.color,
                icon: draft.icon,
                amount: draft.amount,
                fillFraction: fraction,
                transactionCount: draft.transactionCount,
                hasChildren: draft.hasChildren,
                isDirectRemainder: draft.isDirectRemainder
            )
        }
    }
}
