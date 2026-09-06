import SwiftUI

/// The small uppercase label used at the top of every card ("SPESO QUESTO
/// PERIODO", "ALTRE VALUTE", …).
struct EyebrowLabel: View {
    let text: String
    /// Overridable so a section header can carry the brand accent (the
    /// dashboard's cards) or sit on a coloured band (`Palette.onHeroSecondary`
    /// in `HeroCard`). Defaults to the muted metadata tone.
    var color: Color = Palette.inkTertiary

    var body: some View {
        Text(text.uppercased())
            .font(Typography.eyebrow)
            .foregroundStyle(color)
            .kerning(0.6)
    }
}
