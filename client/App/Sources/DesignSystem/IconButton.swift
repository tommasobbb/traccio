import SwiftUI

/// The circular icon-only button used for a per-connection manual sync and
/// the Conti top bar's "add" control (`docs/design/canvas/Accounts.dc.html`).
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
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(accessibilityLabel)
    }
}
