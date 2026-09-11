import SwiftUI
import TraccioCore

/// The "Buoni pasto" card — meal-voucher spending broken out of the
/// dashboard's headline totals (ADR 0029), rendered nothing when empty (the
/// setting is off, there is no voucher account, or nothing was spent), same
/// posture as `AccountBreakdownCard` and every other optional dashboard card.
///
/// An ordinary `Card` at default elevation, not `.raised` — the hero stays
/// the only raised card on the screen (2026-09-08 "dose, non tinta"
/// revision). Reuses `TraccioCore.CategoryBreakdownRow.breakdownRows` and
/// `CategoryBreakdownList` for the per-category split, exactly like the
/// main "Per categoria" card, so the ripartizione comes free from the same
/// components. No drill-through: `GET /transactions` has no voucher-account
/// filter, so tapping a row here would land on a result mixing voucher and
/// non-voucher rows — the same reasoning `AccountBreakdownCard` documents
/// for having none.
struct MealVoucherCard: View {
    let summary: MealVoucherSummaryResponse

    /// This card's own expand/collapse state — independent of the main
    /// "Per categoria" card's `DashboardViewModel.expandedRootIDs`, since
    /// the two show different category sets.
    @State private var expandedRootIDs: Set<UUID> = []

    var body: some View {
        Card {
            EyebrowLabel(text: "Buoni pasto", color: Palette.ink)
            HStack(alignment: .firstTextBaseline) {
                AmountText(
                    amount: summary.spending,
                    currencyCode: summary.currency,
                    kind: .spending,
                    font: Typography.compactFigure
                )
                Spacer(minLength: 8)
                Text(memberCountLabel)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            CategoryBreakdownList(
                rows: TraccioCore.breakdownRows(groups: summary.byCategory, expanded: expandedRootIDs),
                currency: summary.currency,
                totalSpending: summary.spending,
                expandedRootIDs: expandedRootIDs,
                onToggleExpanded: { categoryID in
                    if expandedRootIDs.contains(categoryID) {
                        expandedRootIDs.remove(categoryID)
                    } else {
                        expandedRootIDs.insert(categoryID)
                    }
                }
                // `onDrillThrough` omitted — no per-account filter on
                // `GET /transactions` to drill through to (see
                // `CategoryBreakdownList`'s doc comment).
            )
        }
    }

    private var memberCountLabel: String {
        summary.transactionCount == 1 ? "1 movimento" : "\(summary.transactionCount) movimenti"
    }
}
