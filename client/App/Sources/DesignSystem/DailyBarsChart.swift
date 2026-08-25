import SwiftUI
import TraccioCore

/// The dashboard's "Spesa giornaliera" bar chart — pure presentation, drawn
/// from the geometry `TraccioCore.dailyBars(_:)` already computed and tested.
///
/// Hand-drawn (`RoundedRectangle`), not Swift Charts' `BarMark` — same
/// reasoning as `DonutChart`: the bar/track shape is straightforward here,
/// and the arithmetic that actually needs verifying already lives — and is
/// tested — in `TraccioCore`, not in this view. No dates are rendered inside
/// the chart itself; the caller (`DashboardView`) labels the axis endpoints
/// as text, the same split `DonutChart` has with its legend.
///
/// Decorative only, `.accessibilityHidden(true)`.
struct DailyBarsChart: View {
    let bars: [DailyBar]
    var height: CGFloat = 90
    var barSpacing: CGFloat = 3
    /// Drives the draw-in on appear — every bar grows from zero to its
    /// actual height, rather than popping in already drawn.
    @State private var isDrawn = false

    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Palette.neutralFill)
                        .frame(height: height)
                    // A day with no spending still gets a sliver, so the
                    // track underneath never reads as a missing bar.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Palette.accent)
                        .frame(height: isDrawn ? max(3, height * bar.fraction) : 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                isDrawn = true
            }
        }
    }
}

#Preview {
    DailyBarsChart(
        bars: TraccioCore.dailyBars([
            DaySummaryResponse(
                date: CalendarDate(year: 2026, month: 8, day: 10), spending: 5500, income: 0,
                transactionCount: 2
            ),
            DaySummaryResponse(
                date: CalendarDate(year: 2026, month: 8, day: 11), spending: 1200, income: 0,
                transactionCount: 1
            ),
            DaySummaryResponse(
                date: CalendarDate(year: 2026, month: 8, day: 13), spending: 8300, income: 0,
                transactionCount: 3
            ),
        ])
    )
    .padding(20)
    .background(Palette.background)
}
