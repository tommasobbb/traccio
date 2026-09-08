import SwiftUI

/// The small uppercase label used at the top of every card ("SPESO QUESTO
/// PERIODO", "ALTRE VALUTE", …).
struct EyebrowLabel: View {
    let text: String
    /// Overridable so a section header can be `Palette.ink` (the dashboard's
    /// card titles). Not the accent — an eyebrow is a heading, and the accent
    /// marks what you touch (`docs/design/tokens.md`'s "Accent dosage").
    /// Defaults to the muted metadata tone.
    var color: Color = Palette.inkTertiary

    var body: some View {
        Text(text.uppercased())
            .font(Typography.eyebrow)
            .foregroundStyle(color)
            .kerning(0.6)
    }
}
