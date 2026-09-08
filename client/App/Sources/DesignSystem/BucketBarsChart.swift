import SwiftUI
import TraccioCore

/// The dashboard's "Spesa giornaliera" trend chart — pure presentation, drawn
/// from the geometry `TraccioCore.spendingBars(_:)` already computed and
/// tested, scrub-to-preview backed by the pure
/// `TraccioCore.bucketIndex(atFraction:count:)` (2026-08-26 revision, ADR
/// 0008, Task 6 of the "Daily driver, davvero" milestone).
///
/// Hand-drawn (`RoundedRectangle`), not Swift Charts' `BarMark` — same
/// reasoning as `DonutChart`: the bar/track shape is straightforward here,
/// and the arithmetic that actually needs verifying already lives — and is
/// tested — in `TraccioCore`, not in this view.
///
/// Unlike `DonutChart`, this chart is **not** `.accessibilityHidden(true)`:
/// a bar chart has an idiomatic VoiceOver interaction
/// (`accessibilityAdjustableAction`, swipe up/down to move the selection)
/// that a donut's sectors do not, so it earns its own accessibility rather
/// than needing a separate list alongside it.
///
/// Dragging previews each bucket under the finger in the floating tooltip
/// above the chart (`onScrub`); a plain tap (a drag that barely moved)
/// drills through to Movimenti for that bucket's `[start, end)` (`onDrillThrough`)
/// — a real drag's release does **not** navigate, so scrubbing to read
/// values never accidentally leaves the screen.
struct BucketBarsChart: View {
    let bars: [SpendingBar]
    let currency: String
    /// The bucket currently previewed — bound to
    /// `DashboardViewModel.selectedBucketIndex`.
    let selectedIndex: Int?
    let onScrub: (Int?) -> Void
    let onDrillThrough: (Int) -> Void
    var height: CGFloat = 90
    var barSpacing: CGFloat = 3
    /// Drives the draw-in on appear — every bar grows from zero to its
    /// actual height, rather than popping in already drawn.
    @State private var isDrawn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tooltip
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                        barView(bar, isSelected: index == selectedIndex)
                    }
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: proxy.size.width))
            }
            .frame(height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Andamento spesa")
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction(handleAdjustableAction)
        .sensoryFeedback(.selection, trigger: selectedIndex)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                isDrawn = true
            }
        }
    }

    // MARK: Bars

    private func barView(_ bar: SpendingBar, isSelected: Bool) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Palette.neutralFill)
                .frame(height: height)
            // A bucket with no spending still gets a sliver, so the track
            // underneath never reads as a missing bar. The bars are a muted
            // ink fill at rest — the accent marks only the bar currently
            // scrubbed, per `docs/design/tokens.md`'s "Accent dosage" (a
            // chart-wide blue block was exactly the over-use that revision
            // pulled back).
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? Palette.accent : Palette.ink.opacity(0.16))
                .frame(height: isDrawn ? max(3, height * bar.fraction) : 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Tooltip

    @ViewBuilder
    private var tooltip: some View {
        if let selectedIndex, bars.indices.contains(selectedIndex) {
            let bar = bars[selectedIndex]
            HStack(spacing: 8) {
                Text(TraccioCore.formatCalendarDate(bar.start))
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                AmountText(
                    amount: bar.spending, currencyCode: currency, kind: .spending,
                    font: Typography.caption.weight(.bold)
                )
                Text("· \(bar.transactionCount) movimenti")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.neutralFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
        }
    }

    // MARK: Gesture

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onScrub(index(atX: value.location.x, width: width))
            }
            .onEnded { value in
                let movedFar = abs(value.translation.width) > 5 || abs(value.translation.height) > 5
                guard !movedFar, let index = index(atX: value.location.x, width: width) else { return }
                onDrillThrough(index)
            }
    }

    private func index(atX x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0 else { return nil }
        return TraccioCore.bucketIndex(atFraction: Double(x / width), count: bars.count)
    }

    // MARK: Accessibility

    private var accessibilityValueText: String {
        guard !bars.isEmpty else { return "Nessun dato" }
        let index = selectedIndex.flatMap { bars.indices.contains($0) ? $0 : nil } ?? bars.count - 1
        let bar = bars[index]
        let amount = TraccioCore.formatMoney(amount: bar.spending, currencyCode: currency)
        return "\(TraccioCore.formatCalendarDate(bar.start)), \(amount), \(bar.transactionCount) movimenti"
    }

    private func handleAdjustableAction(_ direction: AccessibilityAdjustmentDirection) {
        guard !bars.isEmpty else { return }
        let current = selectedIndex ?? bars.count - 1
        switch direction {
        case .increment:
            onScrub(min(current + 1, bars.count - 1))
        case .decrement:
            onScrub(max(current - 1, 0))
        @unknown default:
            break
        }
    }
}

#Preview {
    BucketBarsChart(
        bars: TraccioCore.spendingBars([
            BucketSummaryResponse(
                start: CalendarDate(year: 2026, month: 8, day: 10),
                end: CalendarDate(year: 2026, month: 8, day: 11), spending: 5500, income: 0,
                transactionCount: 2
            ),
            BucketSummaryResponse(
                start: CalendarDate(year: 2026, month: 8, day: 11),
                end: CalendarDate(year: 2026, month: 8, day: 12), spending: 1200, income: 0,
                transactionCount: 1
            ),
            BucketSummaryResponse(
                start: CalendarDate(year: 2026, month: 8, day: 12),
                end: CalendarDate(year: 2026, month: 8, day: 13), spending: 8300, income: 0,
                transactionCount: 3
            ),
        ]),
        currency: "EUR",
        selectedIndex: nil,
        onScrub: { _ in },
        onDrillThrough: { _ in }
    )
    .padding(20)
    .background(Palette.background)
}
