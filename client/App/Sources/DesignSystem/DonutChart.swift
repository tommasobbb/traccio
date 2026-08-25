import SwiftUI
import TraccioCore

/// The dashboard's "Per categoria" donut ring — pure presentation, drawn from
/// the geometry `TraccioCore.donutSegments(_:)` already computed and tested.
///
/// Uses the `Circle().trim(from:to:)` idiom rather than Swift Charts'
/// `SectorMark`, per ADR 0008's hand-styled direction: the mockup's rounded
/// caps and inset track (`docs/design/canvas/Main.dc.html`) are
/// straightforward here and awkward to coax out of a chart library, and the
/// arithmetic that actually needs verifying already lives — and is tested —
/// in `TraccioCore`, not in this view.
///
/// Decorative only, `.accessibilityHidden(true)`: the legend rendered
/// alongside it in `DashboardView` is the accessible representation, one row
/// per category with its name and amount as text.
struct DonutChart: View {
    let segments: [DonutSegment]
    var diameter: CGFloat = 116
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
                        Palette.categoryChart(rank: segment.rank),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    // Circle().trim starts at 3 o'clock; rotate so fraction 0
                    // lands at 12 o'clock, matching the mockup and the
                    // legend's reading order (biggest spender first,
                    // clockwise from the top).
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                isDrawn = true
            }
        }
    }
}

#Preview {
    DonutChart(
        segments: TraccioCore.donutSegments([
            CategorySummaryResponse(
                categoryID: UUID(), categoryName: "Casa", spending: 42000, income: 0,
                transactionCount: 4
            ),
            CategorySummaryResponse(
                categoryID: UUID(), categoryName: "Alimentari", spending: 31100, income: 0,
                transactionCount: 12
            ),
            CategorySummaryResponse(
                categoryID: nil, categoryName: nil, spending: 26000, income: 0,
                transactionCount: 5
            ),
        ])
    )
    .padding(40)
    .background(Palette.background)
}
