import SwiftUI

/// The accent pill button ("Rinnova ora" in `docs/design/canvas/Accounts.dc.html`)
/// — the app's one primary-CTA shape ("Accent dosage",
/// `docs/design/tokens.md`), now a Liquid Glass button
/// (`docs/decisions/0030-liquid-glass-chrome.md`): `.glassProminent` tinted
/// with the accent, so the dose stays the same but the surface is chrome
/// material instead of a flat fill.
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
        }
        .buttonStyle(.glassProminent)
        .tint(isLoading ? Palette.accentPressed : Palette.accent)
        .buttonBorderShape(.capsule)
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "\(title) — in corso" : title)
    }
}
