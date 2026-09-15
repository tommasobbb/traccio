import SwiftUI

extension View {
    /// The screen root's background: `Palette.backgroundGradient` instead of
    /// a flat `Palette.background` fill, so the chrome's Liquid Glass
    /// (`docs/decisions/0030-liquid-glass-chrome.md`) has something neutral
    /// to refract. Every `NavigationStack`/sheet root uses this in place of
    /// `.background(Palette.background)`. `Palette.background` itself stays
    /// available for a flat fill that isn't a full SwiftUI screen — the
    /// launch screen's `UIColorName` (`Project.yml`) can only reference a
    /// plain colour asset, not a gradient.
    func screenBackground() -> some View {
        background(Palette.backgroundGradient)
    }
}
