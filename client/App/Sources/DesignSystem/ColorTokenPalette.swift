import SwiftUI
import TraccioCore

/// Maps a backend `PaletteColor` to its `Colors.xcassets` colours.
///
/// A separate file from `Palette.swift` (`.claude/rules/swift.md`: "small,
/// focused files") because this is a mapping *from* a backend-owned
/// vocabulary, not a fixed design token like the rest of `Palette`. Each of
/// the ten tones has its own colorset (`PaletteColor<Name>`) plus a paler
/// `...Tint` counterpart for an icon tile's background — see `IconTile.swift`.
/// Every colorset carries an explicit dark-appearance variant, same
/// convention as the rest of `Palette` (ADR 0008's dark-mode revision).
extension Palette {
    /// The solid colour for `token` — an icon glyph, a legend dot, a fill bar.
    static func color(_ token: PaletteColor) -> Color {
        switch token {
        case .blue: Color("PaletteColorBlue", bundle: .main)
        case .indigo: Color("PaletteColorIndigo", bundle: .main)
        case .purple: Color("PaletteColorPurple", bundle: .main)
        case .pink: Color("PaletteColorPink", bundle: .main)
        case .red: Color("PaletteColorRed", bundle: .main)
        case .orange: Color("PaletteColorOrange", bundle: .main)
        case .amber: Color("PaletteColorAmber", bundle: .main)
        case .green: Color("PaletteColorGreen", bundle: .main)
        case .teal: Color("PaletteColorTeal", bundle: .main)
        case .slate: Color("PaletteColorSlate", bundle: .main)
        }
    }

    /// The pale background for `token` — an icon tile's fill, so the glyph
    /// (in `color(_:)`) reads at full strength on top of it.
    static func tint(_ token: PaletteColor) -> Color {
        switch token {
        case .blue: Color("PaletteColorBlueTint", bundle: .main)
        case .indigo: Color("PaletteColorIndigoTint", bundle: .main)
        case .purple: Color("PaletteColorPurpleTint", bundle: .main)
        case .pink: Color("PaletteColorPinkTint", bundle: .main)
        case .red: Color("PaletteColorRedTint", bundle: .main)
        case .orange: Color("PaletteColorOrangeTint", bundle: .main)
        case .amber: Color("PaletteColorAmberTint", bundle: .main)
        case .green: Color("PaletteColorGreenTint", bundle: .main)
        case .teal: Color("PaletteColorTealTint", bundle: .main)
        case .slate: Color("PaletteColorSlateTint", bundle: .main)
        }
    }
}
