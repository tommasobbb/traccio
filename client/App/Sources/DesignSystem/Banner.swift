import SwiftUI

/// A warning surface for a message that needs attention before the user
/// forgets — the consent-expiry banner on Conti
/// (`docs/design/canvas/Accounts.dc.html`), and generic enough to reuse for a
/// failed sync.
///
/// Built only from tokens already in `docs/design/tokens.md`: `warningTint`/
/// `warningBorder` for the surface, `warningInk` for the title (`warning`
/// itself is too low-contrast for small bold text on that background — see
/// the tokens doc).
struct Banner: View {
    let message: String
    var ctaTitle: String?
    var isCTALoading: Bool = false
    var ctaAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(Palette.warningInk)
                if let ctaTitle, let ctaAction {
                    PillButton(title: ctaTitle, isLoading: isCTALoading, action: ctaAction)
                }
            }
        }
        .padding(16)
        .background(Palette.warningTint)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.warningBorder, lineWidth: 1)
        )
    }
}
