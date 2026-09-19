import SwiftUI

/// The circular icon-only button used for a per-connection manual sync, a
/// category row's add/edit/delete controls, and similar in-content actions.
/// `IconButtonLabel` below is the same shape without the `Button` wrapper,
/// for a `Menu` that needs to wear it (`RuleRow`'s overflow menu).
///
/// A flat `Circle().fill(background)` — chrome carries Liquid Glass
/// (`docs/decisions/0030-liquid-glass-chrome.md`), a control living inside a
/// screen's own content does not
/// (`docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md`).
/// `.pressable` restores the press feedback glass's own `.interactive()`
/// gave, without the material.
///
/// Icon-only controls need an explicit `accessibilityLabel` — a decorative
/// SF Symbol carries no label of its own (ADR 0008: accessibility is day-one,
/// not a follow-up).
struct IconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var background: Color = Palette.neutralFill
    var foreground: Color = Palette.inkSecondary
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconButtonLabel(
                systemImage: systemImage, background: background, foreground: foreground,
                isLoading: isLoading
            )
        }
        .buttonStyle(.pressable)
        .disabled(isLoading)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The circular glyph-in-a-fill shape `IconButton` wears, pulled out so a
/// `Menu` (which can't be a `Button`'s label — `RuleRow`'s trailing overflow
/// menu needs the same circular chrome a plain delete `IconButton` used to
/// have) can wear it too, without duplicating the `ZStack`.
struct IconButtonLabel: View {
    let systemImage: String
    var background: Color = Palette.neutralFill
    var foreground: Color = Palette.inkSecondary
    var isLoading: Bool = false

    var body: some View {
        ZStack {
            Circle().fill(background)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(foreground)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)
            }
        }
        .frame(width: 36, height: 36)
    }
}
