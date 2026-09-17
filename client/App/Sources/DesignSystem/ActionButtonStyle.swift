import SwiftUI

/// The solid accent CTA fill shared by `PillButton`, the Filtri sheet's
/// "Applica" button, and `TrackingStartView`'s primary button — a capsule or
/// a rounded rectangle, `Palette.accent` at rest and `Palette.accentPressed`
/// while pressed or in flight.
///
/// Glass is chrome only (`docs/decisions/0030-liquid-glass-chrome.md`,
/// narrowed by `docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md`):
/// a button living inside a screen's own scrollable content is not chrome,
/// so it goes back to the flat fill all three call sites shared before ADR
/// 0030, shared here instead of hand-rolled three times. A quieter
/// "secondary" button is not part of this style — `TrackingStartView`'s and
/// `TransferSuggestionCard`'s each predate ADR 0030 with a different look
/// (card+border vs. neutralFill+ink) and stay hand-written rather than
/// forced into a shape neither of them actually had.
struct ActionButtonStyle: ButtonStyle {
    enum Shape {
        case capsule
        case roundedRectangle(CGFloat)
    }

    var shape: Shape = .capsule
    /// Tints the fill with `Palette.accentPressed` while the action is in
    /// flight, same treatment as a pressed state.
    var isLoading: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(fill(pressed: configuration.isPressed), in: clipShape)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        (isLoading || pressed) ? Palette.accentPressed : Palette.accent
    }

    private var clipShape: AnyShape {
        switch shape {
        case .capsule: AnyShape(Capsule())
        case .roundedRectangle(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    /// The app's one primary-CTA fill ("Accent dosage", `docs/design/tokens.md`).
    static func action(shape: ActionButtonStyle.Shape = .capsule, isLoading: Bool = false) -> ActionButtonStyle {
        ActionButtonStyle(shape: shape, isLoading: isLoading)
    }
}
