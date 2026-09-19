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
/// render after it. Nothing here truncates: each line wraps on its own terms
/// instead.
struct DashboardStatsCard: View {
    let summary: CurrencySummaryResponse
    /// The previous period's display title, for `comparisonText` — computed
    /// by the caller (`DashboardView`) via `CalendarPeriod.displayTitle`.
    let previousPeriodTitle: String
    /// The line under the stats — "Convertito in EUR ai tassi BCE · dd/MM" or
    /// "Totale combinato non disponibile al momento." — or `nil` when neither
    /// applies (FX off and every currency accounted for).
    let caption: String?

    var body: some View {
        Card(elevation: .flush) {
            VStack(alignment: .leading, spacing: Spacing.tightGap) {
                if let comparison = summary.comparison {
                    comparisonLine(comparison)
                }
                statsLine
                if let caption {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func comparisonLine(_ c: ComparisonSummaryResponse) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: comparisonImage(c))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(comparisonColor(c))
            Text(comparisonText(c, currency: summary.currency))
                .font(Typography.caption)
                .foregroundStyle(comparisonColor(c))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Media/giorno, N movimenti, N categorie, dot-joined. A non-breaking
    /// space between each number and its unit means a wrap (now that the
    /// card gives this room to happen) can only land on a "·" boundary, never
    /// inside "18 mov.".
    private var statsLine: some View {
        let stats = [
            summary.averageDailySpending.map {
                "\(TraccioCore.formatMoney(amount: $0, currencyCode: summary.currency))\u{00A0}/g"
            },
            "\(summary.transactionCount)\u{00A0}mov.",
            "\(summary.byCategory.filter { $0.spending > 0 }.count)\u{00A0}cat.",
        ].compactMap { $0 }

        return Text(stats.joined(separator: " · "))
            .font(Typography.caption)
            .foregroundStyle(Palette.inkTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func comparisonImage(_ c: ComparisonSummaryResponse) -> String {
        if c.spendingDelta > 0 { return "arrow.up.right" }
        if c.spendingDelta < 0 { return "arrow.down.right" }
        return "minus"
    }

    /// Spending up carries `warning` (a genuine flag); spending down or flat
    /// stays ink — the direction is already in the words ("in meno"), and the
    /// dashboard keeps blue off its chrome (2026-09-08 tone revision, second
    /// pass).
    private func comparisonColor(_ c: ComparisonSummaryResponse) -> Color {
        if c.spendingDelta > 0 { return Palette.warning }
        return Palette.inkTertiary
    }

    /// "12% in più di agosto" / "12% in meno di agosto", or the signed amount
    /// when the previous period spent nothing (no percentage).
    private func comparisonText(_ c: ComparisonSummaryResponse, currency: String) -> String {
        guard let pct = c.spendingDeltaPct else {
            let amount = TraccioCore.formatMoney(
                amount: c.spendingDelta, currencyCode: currency, explicitSign: true
            )
            return "\(amount) su \(previousPeriodTitle)"
        }
        let percentage = abs(TraccioCore.roundedPercentage(pct))
        let direction = c.spendingDelta > 0 ? "in più" : "in meno"
        return "\(percentage)% \(direction) di \(previousPeriodTitle)"
    }
}
