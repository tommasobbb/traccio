import SwiftUI

/// A thin horizontal progress track — a neutral capsule with a coloured fill
/// clamped to `[0, 1]`. The reimbursement "quanto è rientrato" bar on the
/// advance detail and on a person's drill-down both draw this, rather than
/// each rolling its own `GeometryReader`.
///
/// Presentation only: the caller passes an already-computed `fraction`
/// (`reimbursed / receivable`, server figures), this view never divides.
struct ProgressBar: View {
    /// Fill fraction; values outside `0...1` are clamped.
    let fraction: Double
    /// The fill colour. Defaults to `Palette.income` — money coming back.
    var tint: Color = Palette.income
    /// Track thickness.
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.625, style: .continuous)
                    .fill(Palette.neutralFill)
                RoundedRectangle(cornerRadius: height * 0.625, style: .continuous)
                    .fill(tint)
                    .frame(width: geometry.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var clamped: CGFloat { CGFloat(min(1, max(0, fraction))) }
}
