import SwiftUI
import TraccioCore

/// The dashboard's "Per categoria" donut ring — pure presentation, drawn from
/// the geometry `TraccioCore.donutSegments(_:)` already computed and tested,
/// tap-to-select backed by the pure `TraccioCore.fraction(forPoint:in:)`/
/// `segment(atFraction:in:)` hit test (2026-08-26 revision, ADR 0008).
///
/// Uses the `Circle().trim(from:to:)` idiom rather than Swift Charts'
/// `SectorMark`, per ADR 0008's hand-styled direction: the mockup's rounded
/// caps and inset track (`docs/design/canvas/Main.dc.html`) are
/// straightforward here and awkward to coax out of a chart library, and the
/// arithmetic that actually needs verifying already lives — and is tested —
/// in `TraccioCore`, not in this view.
///
/// Decorative only, `.accessibilityHidden(true)`: `CategoryBreakdownList`
/// rendered alongside it in `DashboardView` is the accessible
/// representation, one focusable, activatable row per category with its
/// name, amount, and percentage as text.
struct DonutChart: View {
    let segments: [DonutSegment]
    /// The currently highlighted category, or `.none`. Read-only here — a
    /// tap resolves a segment and reports it via `onSelect`, letting
    /// `DashboardViewModel` own the toggle-on-same-tap logic in one place
    /// rather than duplicating it between this view and
    /// `CategoryBreakdownList`.
    let selection: DashboardViewModel.DonutSelection
    let onSelect: (UUID?) -> Void
    var diameter: CGFloat = 96
    var lineWidth: CGFloat = 14
    /// Drives the draw-in on appear — each segment starts collapsed to its
    /// own `startFraction` and animates out to `endFraction`, rather than
    /// popping in already drawn.
    @State private var isDrawn = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.neutralFill, style: StrokeStyle(lineWidth: lineWidth))
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Circle()
                    .trim(
                        from: segment.startFraction,
                        to: isDrawn ? segment.endFraction : segment.startFraction
                    )
                    .stroke(
                        Palette.color(segment.color),
                        style: StrokeStyle(lineWidth: strokeWidth(for: segment), lineCap: .round)
                    )
                    .opacity(opacity(for: segment))
                    // Circle().trim starts at 3 o'clock; rotate so fraction 0
                    // lands at 12 o'clock, matching the mockup and
                    // TraccioCore.fraction(forPoint:in:)'s own convention.
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in handleTap(at: value.location) }
        )
        .accessibilityHidden(true)
        .sensoryFeedback(.selection, trigger: selection)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                isDrawn = true
            }
        }
    }

    private func handleTap(at location: CGPoint) {
        let center = diameter / 2
        let point = (x: Double(location.x - center), y: Double(location.y - center))
        let geometry = DonutGeometry(diameter: Double(diameter), lineWidth: Double(lineWidth))
        guard let fraction = TraccioCore.fraction(forPoint: point, in: geometry),
            let hit = TraccioCore.segment(atFraction: fraction, in: segments)
        else { return }
        onSelect(hit.categoryID)
    }

    private func isSelected(_ segment: DonutSegment) -> Bool {
        selection == .category(segment.categoryID)
    }

    /// Full opacity when nothing is selected (the original, non-interactive
    /// look) or for the selected segment itself; every other segment dims to
    /// let the selection read clearly.
    private func opacity(for segment: DonutSegment) -> Double {
        guard selection != .none else { return 1 }
        return isSelected(segment) ? 1 : 0.35
    }

    private func strokeWidth(for segment: DonutSegment) -> CGFloat {
        isSelected(segment) ? lineWidth * 1.3 : lineWidth
    }
}

#Preview {
    DonutChart(
        segments: TraccioCore.donutSegments([
            CategoryGroupSummaryResponse(
                categoryID: UUID(), categoryName: "Casa", color: .indigo, icon: nil, spending: 42000,
                income: 0, transactionCount: 4, directSpending: 42000, directIncome: 0,
                directTransactionCount: 4
            ),
            CategoryGroupSummaryResponse(
                categoryID: UUID(), categoryName: "Alimentari", color: .green, icon: nil,
                spending: 31100, income: 0, transactionCount: 12, directSpending: 31100,
                directIncome: 0, directTransactionCount: 12
            ),
            CategoryGroupSummaryResponse(
                categoryID: nil, categoryName: nil, color: .slate, icon: nil, spending: 26000,
                income: 0, transactionCount: 5, directSpending: 26000, directIncome: 0,
                directTransactionCount: 5
            ),
        ]),
        selection: .none,
        onSelect: { _ in }
    )
    .padding(40)
    .background(Palette.background)
}
