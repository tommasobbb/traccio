import SwiftUI
import TraccioCore

/// The quiet stats that used to sit loose on the background under the hero
/// — the period comparison, the three secondary stats, and the FX/"totale non
/// disponibile" caption — now in their own `.flush` card directly below the
/// hero. `.flush` deliberately: one elevation step under the hero's
/// `.raised`, so the hierarchy still reads hero-first (`docs/design/tokens.md`'s
/// "Accent dosage"), and `Card`'s `.flush` corner radius is `Radius.row` (16),
/// smaller than the hero's `Radius.card` (20), which reinforces it.
///
/// Replaces `DashboardHeroFootnote` (a bare `HStack` that truncated at
/// `.lineLimit(1)`) and the two loose `Text` captions `DashboardView` used to
/// render after it.
///
/// **Rewritten 2026-09-19** from three lines of `Typography.caption` text
/// (the delta, then a dot-joined stats line) to three figure columns — the
/// same idiom as the hero's own Entrate/Netto pair
/// (`DashboardHeroCard.swift`), so the screen doesn't learn a second way to
/// show a pair of stats. The month-over-month delta had the same type scale
/// as a footnote; a comparison the owner actually wants to register at a
/// glance needs to read at more than 13pt.
///
/// **Revised again 2026-09-19 (third batch this day):** the comparison moved
/// out of the equal-width column grid onto its own full-width row above it.
/// Three `.frame(maxWidth: .infinity)` columns gave the comparison (a
/// direction arrow + a figure + "su Agosto 2026") the same third of the card
/// as "movimenti" — on a 390pt device that's ~90pt, not enough for either the
/// figure or the label, so both truncated ("+ 67…" / "su Agosto 2…"). This is
/// the column-grid version of the "Text never wraps" section's `.fixedSize`
/// warning in `docs/design/tokens.md`: giving every sibling an equal fixed
/// share works only when at least one of them can actually shrink to fit.
struct DashboardStatsCard: View {
    let summary: CurrencySummaryResponse
    /// The previous period's display title, for the comparison row's label —
    /// computed by the caller (`DashboardView`) via `CalendarPeriod.displayTitleInline`
    /// (lowercase, since it reads inline after "su").
    let previousPeriodTitle: String
    /// The line under the columns — "Convertito in EUR ai tassi BCE · dd/MM" or
    /// "Totale combinato non disponibile al momento." — or `nil` when neither
    /// applies (FX off and every currency accounted for).
    let caption: String?

    var body: some View {
        Card(elevation: .flush) {
            VStack(alignment: .leading, spacing: Spacing.cardSectionGap) {
                if let comparison = summary.comparison {
                    comparisonRow(comparison)
                    Divider().overlay(Palette.separatorSubtle)
                }
                columns
                if let caption {
                    Divider().overlay(Palette.separatorSubtle)
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The month-over-month comparison, full-width above the columns — see
    /// this type's 2026-09-19 doc comment for why it left the column grid.
    private func comparisonRow(_ c: ComparisonSummaryResponse) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: comparisonImage(c))
                    .font(.system(size: 13, weight: .bold))
                Text(comparisonFigureText(c, currency: summary.currency))
                    .font(Typography.statFigure)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(comparisonColor(c))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text("su \(previousPeriodTitle)")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        }
    }

    /// Up to two columns, both optional: a period with zero elapsed days has
    /// no `averageDailySpending`, and the volume column is always shown. A
    /// trailing divider after the average column is always correct since the
    /// volume column always follows it when present.
    @ViewBuilder
    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            if let averageDailySpending = summary.averageDailySpending {
                averageColumn(averageDailySpending)
                columnDivider
            }
            volumeColumn
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: 1)
            .padding(.horizontal, Spacing.itemGap)
    }

    /// One column: a `Typography.statFigure`-scale figure over a caption
    /// label, matching the hero's Entrate/Netto pair. `.minimumScaleFactor`
    /// on the figure and `.lineLimit(1)` on both keep two columns from
    /// overflowing the card at large Dynamic Type sizes.
    private func column<Figure: View>(
        label: String, @ViewBuilder figure: () -> Figure
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            figure()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func averageColumn(_ amount: Int) -> some View {
        column(label: "al giorno") {
            AmountText(
                amount: amount, currencyCode: summary.currency, kind: .spending,
                font: Typography.statFigure
            )
        }
    }

    private var volumeColumn: some View {
        column(label: "movimenti") {
            Text("\(summary.transactionCount)")
                .font(Typography.statFigure)
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText(value: Double(summary.transactionCount)))
        }
    }

    private func comparisonImage(_ c: ComparisonSummaryResponse) -> String {
        if c.spendingDelta > 0 { return "arrow.up.right" }
        if c.spendingDelta < 0 { return "arrow.down.right" }
        return "minus"
    }

    /// Spending up carries `warning` (a genuine flag); spending down or flat
    /// stays ink — the direction is already in the figure's sign and the
    /// arrow, and the dashboard keeps blue off its chrome (2026-09-08 tone
    /// revision, second pass). Never red: spending stays in ink even here
    /// (`docs/design/tokens.md`).
    private func comparisonColor(_ c: ComparisonSummaryResponse) -> Color {
        if c.spendingDelta > 0 { return Palette.warning }
        return Palette.ink
    }

    /// "−12%" / "+12%", or the signed amount when the previous period spent
    /// nothing (no percentage to compute).
    private func comparisonFigureText(_ c: ComparisonSummaryResponse, currency: String) -> String {
        guard let pct = c.spendingDeltaPct else {
            return TraccioCore.formatMoney(
                amount: c.spendingDelta, currencyCode: currency, explicitSign: true
            )
        }
        let percentage = TraccioCore.roundedPercentage(pct)
        let sign = percentage > 0 ? "+" : (percentage < 0 ? "−" : "")
        return "\(sign)\(abs(percentage))%"
    }
}
