import SwiftUI

/// The small uppercase label used at the top of every card ("SPESO QUESTO
/// PERIODO", "ALTRE VALUTE", …).
struct EyebrowLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Typography.eyebrow)
            .foregroundStyle(Palette.inkTertiary)
            .kerning(0.6)
    }
}
