import SwiftUI
import TraccioCore

/// The "Rispetto a [periodo precedente]" card — Task 6's period comparison,
/// `ComparisonSummaryResponse` finally rendered now that `GET
/// /dashboard/summary` always requests one (`DashboardViewModel.load()`
/// sends `compareStart`/`compareEnd` from `period.previous()`
/// unconditionally).
///
/// The delta's color is its own small rule, deliberately not routed through
/// `AmountText`: none of `AmountText.Kind`'s four cases mean "spending went
/// up or down versus another period" (`.net`'s "accent when positive" is the
/// wrong valence here — a *positive* delta means spending increased, which
/// is not the good news `.net`'s accent implies), so this card decides its
/// own two colors rather than stretching an existing case to fit.
struct ComparisonCard: View {
    let comparison: ComparisonSummaryResponse
    let currency: String
    /// Display label for the comparison period (e.g. "luglio 2026") — built
    /// by the caller from `CalendarPeriod`, presentation copy that does not
    /// belong in this view's own logic.
    let previousPeriodLabel: String

    var body: some View {
        Card {
            EyebrowLabel(text: "Rispetto a \(previousPeriodLabel)", color: Palette.accent)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: deltaSystemImage)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(deltaColor)
                Text(
                    TraccioCore.formatMoney(
                        amount: comparison.spendingDelta, currencyCode: currency, explicitSign: true
                    )
                )
                .font(Typography.statFigure)
                .foregroundStyle(deltaColor)
                Text(percentageText)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Text(
                "Avevi speso \(TraccioCore.formatMoney(amount: comparison.spending, currencyCode: currency)) nel periodo precedente."
            )
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
        }
    }

    private var deltaSystemImage: String {
        if comparison.spendingDelta > 0 { return "arrow.up.right" }
        if comparison.spendingDelta < 0 { return "arrow.down.right" }
        return "minus"
    }

    private var deltaColor: Color {
        if comparison.spendingDelta > 0 { return Palette.warning }
        if comparison.spendingDelta < 0 { return Palette.accent }
        return Palette.inkTertiary
    }

    /// `spendingDeltaPct` is `nil` when the comparison period spent nothing
    /// at all (division by zero, per the backend's own docstring) — shown as
    /// "—", never a fabricated percentage.
    private var percentageText: String {
        guard let pct = comparison.spendingDeltaPct else { return "—" }
        let percentage = Int((pct * 100).rounded())
        return percentage > 0 ? "+\(percentage)%" : "\(percentage)%"
    }
}
