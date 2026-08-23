import SwiftUI

/// The accent pill button ("Rinnova ora" in `docs/design/canvas/Accounts.dc.html`)
/// — the first control in the design system with a pressed/in-flight state,
/// finally putting `Palette.accentPressed` to use.
struct PillButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
                Text(title)
                    .font(Typography.eyebrow)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isLoading ? Palette.accentPressed : Palette.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "\(title) — in corso" : title)
    }
}
