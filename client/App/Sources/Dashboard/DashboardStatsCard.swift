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
struct DashboardStatsCard: View {
    let summary: CurrencySummaryResponse
    /// The previous period's display title, for the delta column's label —
    /// computed by the caller (`DashboardView`) via `CalendarPeriod.displayTitle`.
    let previousPeriodTitle: String
    /// The line under the columns — "Convertito in EUR ai tassi BCE · dd/MM" or
    /// "Totale combinato non disponibile al momento." — or `nil` when neither
    /// applies (FX off and every currency accounted for).
    let caption: String?

    var body: some View {
        Card(elevation: .flush) {
            VStack(alignment: .leading, spacing: Spacing.cardSectionGap) {
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

    /// Up to three columns, each optional except the movement count: a
    /// first period in the app's lifetime has no `comparison`, and a period
    /// with zero elapsed days has no `averageDailySpending`. The volume
    /// column is always last, so a trailing divider after either optional
    /// column is always correct without tracking which column is actually
    /// last.
    @ViewBuilder
    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            if let comparison = summary.comparison {
                comparisonColumn(comparison)
                columnDivider
            }
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
    /// on the figure and `.lineLimit(1)` on both keep three columns from
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

    private func comparisonColumn(_ c: ComparisonSummaryResponse) -> some View {
        column(label: "su \(previousPeriodTitle)") {
            HStack(spacing: 4) {
                Image(systemName: comparisonImage(c))
                    .font(.system(size: 13, weight: .bold))
                Text(comparisonFigureText(c, currency: summary.currency))
                    .font(Typography.statFigure)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(comparisonColor(c))
        }
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
