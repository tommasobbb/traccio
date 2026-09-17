import SwiftUI

/// The accent pill button ("Rinnova ora" in `docs/design/canvas/Accounts.dc.html`)
/// — the app's one primary-CTA shape ("Accent dosage",
/// `docs/design/tokens.md`): a solid `Palette.accent` capsule, white text,
/// via the shared `ActionButtonStyle`
/// (`docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md` —
/// glass is chrome only, this button lives inside a screen's own content).
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.action(isLoading: isLoading))
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "\(title) — in corso" : title)
    }
}
