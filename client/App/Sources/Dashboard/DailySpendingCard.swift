import SwiftUI
import TraccioCore

/// The trend card (`docs/design/canvas/Main.dc.html`'s "Andamento netto"
/// slot, rebuilt as a spending bar chart rather than a net line — ADR 0007's
/// 2026-08-25 revision). Renders nothing when there is nothing to show, same
/// posture as `DashboardHeroCard`'s and `CategoryBreakdownCard`'s own empty
/// branches.
///
/// Uses the same period the rest of the screen shows — no independent
/// selector. Bucketed at `period.granularity` (day/week/month per unit, Task
/// 6), and the backend gap-fills `by_bucket` across the whole requested
/// period since both bounds are always sent, so `spendingBars(_:)` never
/// needs to reconcile a mismatch between the axis and the screen's period.
struct DailySpendingCard: View {
    let summary: CurrencySummaryResponse
    let selectedBucketIndex: Int?
    let onScrub: (Int?) -> Void
    /// Given a bucket's start/end, resolves the drill-through filter (`nil`
    /// when it can't, e.g. unparseable bucket bounds) — the caller
    /// (`DashboardView`) requests it via `TransactionsDrillThrough`.
    let onDrillThrough: (CalendarDate, CalendarDate) -> Void

    var body: some View {
        let bars = TraccioCore.spendingBars(summary.byBucket)

        if !bars.isEmpty {
            Card {
                EyebrowLabel(text: "Andamento spesa", color: Palette.ink)
                BucketBarsChart(
                    bars: bars,
                    currency: summary.currency,
                    selectedIndex: selectedBucketIndex,
                    onScrub: onScrub,
                    onDrillThrough: { index in
                        guard bars.indices.contains(index) else { return }
                        let bar = bars[index]
                        onDrillThrough(bar.start, bar.end)
                    }
                )
            }
        }
    }
}
