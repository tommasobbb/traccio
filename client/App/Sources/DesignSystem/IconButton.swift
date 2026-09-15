import SwiftUI

/// The circular icon-only button used for a per-connection manual sync and
/// the Conti top bar's "add" control (`docs/design/canvas/Accounts.dc.html`).
///
/// A Liquid Glass circle (`docs/decisions/0030-liquid-glass-chrome.md`)
/// tinted with `background` rather than a flat `Circle().fill(_:)` — chrome,
/// same as every other control in this file, never a content surface.
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
            Group {
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
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(background).interactive(), in: Circle())
        .disabled(isLoading)
        .accessibilityLabel(accessibilityLabel)
    }
}
