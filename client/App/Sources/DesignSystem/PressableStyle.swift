import SwiftUI

/// The press feedback for a tappable row or card: a small scale-down plus a
/// faint `ink` veil while the finger is down, springing back on release.
/// Replaces a bare `.buttonStyle(.plain)` on things that navigate or open a
/// sheet — the haptics were already there (`.sensoryFeedback`), this is the
/// visual half (ADR 0008's 2026-09-08 "dose, non tinta" revision).
///
/// Deliberately not the accent: a pressed state is still just chrome
/// (`docs/design/tokens.md`'s "Accent dosage").
struct PressableButtonStyle: ButtonStyle {
    /// How far the content scales down at full press. Rows want a barely-there
    /// value; a standalone card can take a little more.
    var scale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                Palette.ink
                    .opacity(configuration.isPressed ? 0.06 : 0)
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Standalone tappable card (a suggestion card, a connection row).
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// A full-bleed list row inside a grouped card — veil, almost no scale, so
    /// the row does not visibly detach from its neighbours' hairlines.
    static var pressableRow: PressableButtonStyle { PressableButtonStyle(scale: 0.995) }
}
