import SwiftUI
import TraccioCore

/// The "Per categoria" card (`docs/design/canvas/Main.dc.html`), the mockup
/// element the "Concept · richiede backend" badge blocked until
/// `GET /dashboard/summary` started returning `by_category`. Renders nothing
/// when there is nothing to show, rather than an empty donut — same posture
/// as `DashboardHeroCard`'s own empty-period branch.
///
/// 2026-08-26 revision (ADR 0008): the donut shrinks and gains tap-to-select,
/// its center switches between the selected category and the period total,
/// and the old position-paired side legend is replaced by
/// `CategoryBreakdownList` — a full-width, expandable, drill-through-able
/// list that is also this card's accessible representation of the
/// (`.accessibilityHidden(true)`) donut.
struct CategoryBreakdownCard: View {
    let summary: CurrencySummaryResponse
    let selectedCategoryID: DashboardViewModel.DonutSelection
    let expandedRootIDs: Set<UUID>
    let onSelectCategory: (UUID?) -> Void
    let onToggleExpanded: (UUID) -> Void
    let onDrillThrough: (UUID?) -> Void

    /// The donut's fixed size — also the max width for its center label, so a
    /// category name doesn't overflow the ring's hole.
    private let donutDiameter: CGFloat = 96

    var body: some View {
        let segments = TraccioCore.donutSegments(summary.byCategory)

        if !segments.isEmpty {
            Card {
                EyebrowLabel(text: "Per categoria", color: Palette.ink)
                HStack {
                    Spacer(minLength: 0)
                    ZStack {
                        DonutChart(
                            segments: segments,
                            selection: selectedCategoryID,
                            onSelect: onSelectCategory,
                            diameter: donutDiameter
                        )
                        donutCenter
                    }
                    Spacer(minLength: 0)
                }
                CategoryBreakdownList(
                    rows: TraccioCore.breakdownRows(
                        groups: summary.byCategory, expanded: expandedRootIDs
                    ),
                    currency: summary.currency,
                    totalSpending: summary.spending,
                    expandedRootIDs: expandedRootIDs,
                    onToggleExpanded: onToggleExpanded,
                    onDrillThrough: onDrillThrough
                )
            }
        }
    }

    /// The donut's center label — the selected category's own name and
    /// amount, or the period total when nothing is selected. A selection
    /// whose category no longer resolves against `summary.byCategory` (a
    /// stale id after a reload race) falls back to the total, same as no
    /// selection at all.
    @ViewBuilder
    private var donutCenter: some View {
        let selectedGroup: CategoryGroupSummaryResponse? = {
            guard case .category(let categoryID) = selectedCategoryID else { return nil }
            return summary.byCategory.first { $0.categoryID == categoryID }
        }()

        VStack(spacing: 2) {
            AmountText(
                amount: selectedGroup?.spending ?? summary.spending,
                currencyCode: summary.currency,
                kind: .spending,
                font: Typography.compactFigure
            )
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            Text(selectedGroup.map { $0.categoryName ?? "Senza categoria" } ?? "totale")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: donutDiameter - 32)
    }
}
