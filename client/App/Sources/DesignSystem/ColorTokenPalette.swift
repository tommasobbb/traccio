import SwiftUI
import TraccioCore

/// Maps a backend `PaletteColor` to its `Colors.xcassets` colours.
///
/// A separate file from `Palette.swift` (`docs/engineering.md`: "small,
/// focused files") because this is a mapping *from* a backend-owned
/// vocabulary, not a fixed design token like the rest of `Palette`. Each of
/// the ten tones ships as one colorset (`PaletteColor<Name>`) with an explicit
/// dark-appearance variant, same convention as the rest of `Palette` (ADR
/// 0008's dark-mode revision).
///
/// There was a paler `...Tint` counterpart per tone until ADR 0008's
/// 2026-09-08 tone revision, when `IconTile` — its only consumer — moved to a
/// solid fill with a white glyph; the tint colorsets went with it.
extension Palette {
    /// The solid colour for `token` — a filled icon tile, a legend dot, a
    /// donut/ribbon segment, a fill bar.
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
}
