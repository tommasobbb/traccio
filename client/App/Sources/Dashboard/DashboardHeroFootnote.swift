import SwiftUI
import TraccioCore

/// A single quiet line under the hero card, on the background — the period
/// comparison and the three secondary stats (media/giorno, movimenti,
/// categorie) that used to be a second and third crammed section inside the
/// hero body and a whole `ComparisonCard` of their own (2026-09-08 tone
/// revision, Panoramica recompose). The comparison chunk keeps
/// `ComparisonCard`'s old two-colour rule: a rise in spend is `warning`, a
/// fall is `accent`.
struct DashboardHeroFootnote: View {
    let summary: CurrencySummaryResponse
    /// The previous period's display title, for `comparisonText` — computed
    /// by the caller (`DashboardView`) via `CalendarPeriod.displayTitle`.
    let previousPeriodTitle: String

    var body: some View {
        let stats = [
            summary.averageDailySpending.map {
                "\(TraccioCore.formatMoney(amount: $0, currencyCode: summary.currency))/g"
            },
            "\(summary.transactionCount) mov.",
            "\(summary.byCategory.filter { $0.spending > 0 }.count) cat.",
        ].compactMap { $0 }

        HStack(spacing: 6) {
            if let comparison = summary.comparison {
                Image(systemName: comparisonImage(comparison))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(comparisonColor(comparison))
                Text(comparisonText(comparison, currency: summary.currency))
                    .font(Typography.caption)
                    .foregroundStyle(comparisonColor(comparison))
                Text("·").font(Typography.caption).foregroundStyle(Palette.inkQuaternary)
            }
            Text(stats.joined(separator: " · "))
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
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
