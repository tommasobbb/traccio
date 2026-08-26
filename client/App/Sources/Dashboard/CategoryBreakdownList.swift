import SwiftUI
import TraccioCore

/// The full-width, interactive replacement for the dashboard's old
/// position-paired legend (2026-08-26 revision, ADR 0008) — one
/// `BreakdownRowView` per `TraccioCore.CategoryBreakdownRow`, and this list's
/// own accessible representation of the (`.accessibilityHidden(true)`) donut.
///
/// A direct-spending remainder row (`row.isDirectRemainder`) never gets
/// `onDrillThrough`: `GET /transactions?category_id=<root>` rolls a root's
/// children into the result (ADR 0018), so it cannot express "this root's
/// own transactions, excluding its children" — the one filter this
/// particular row would need. Rather than drill through to a result that
/// silently includes more than the row shows, it stays a plain, non-tappable
/// row (see `DashboardViewModel.drillThroughFilter(categoryID:)`'s own doc
/// comment).
struct CategoryBreakdownList: View {
    let rows: [CategoryBreakdownRow]
    let currency: String
    let totalSpending: Int
    let expandedRootIDs: Set<UUID>
    let onToggleExpanded: (UUID) -> Void
    let onDrillThrough: (UUID?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                BreakdownRowView(
                    row: row,
                    currency: currency,
                    totalSpending: totalSpending,
                    isExpanded: row.categoryID.map(expandedRootIDs.contains) ?? false,
                    onToggleExpanded: {
                        if let categoryID = row.categoryID {
                            onToggleExpanded(categoryID)
                        }
                    },
                    onDrillThrough: row.isDirectRemainder ? nil : { onDrillThrough(row.categoryID) }
                )
                .padding(.vertical, 8)
                if row.id != rows.last?.id {
                    Divider().overlay(Palette.separatorSubtle)
                }
            }
        }
    }
}
