import SwiftUI

/// The circular icon-only button used for a per-connection manual sync and
/// the Conti top bar's "add" control (`docs/design/canvas/Accounts.dc.html`).
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
        .buttonStyle(.pressable)
        .disabled(isLoading)
        .accessibilityLabel(accessibilityLabel)
    }
}
