import SwiftUI

/// A small uppercase pill used to tag a transaction row — the role label
/// ("Trasferimento", "Anticipo", "Rimborso") and the pending marker ("In
/// lavorazione"), per `docs/design/canvas/Transactions.dc.html`.
///
/// Built only from tokens already in `docs/design/tokens.md` — the pill
/// radius (999) and existing surface/ink/accent/warning colors — rather than
/// introducing a new hex the tokens doc doesn't record. `.accent` derives its
/// tint from `Palette.accent` the same way `Palette.separator` derives from
/// `Palette.ink`, instead of a hardcoded new color.
struct Badge: View {
    /// Which semantic tone the badge carries.
    enum Style {
        /// Pending settlement — amber, matching the consent-expiry warning
        /// tone in `Palette`.
        case warning
        /// A transfer or reimbursement — neutral, no color claim beyond
        /// "not a plain personal spend".
        case neutral
        /// An advance — the one role tinted with the brand accent.
        case accent

        var foreground: Color {
            switch self {
            case .warning: Palette.warning
            case .neutral: Palette.inkSecondary
            case .accent: Palette.accent
            }
        }

        var background: Color {
            switch self {
            case .warning: Palette.warningTint
            case .neutral: Palette.neutralFill
            case .accent: Palette.accent.opacity(0.12)
            }
        }
    }

    let text: String
    let style: Style

    var body: some View {
        Text(text.uppercased())
            .font(Typography.eyebrow)
            .foregroundStyle(style.foreground)
            // Never wrap (`docs/design/tokens.md`): a two-word label like
            // "IN LAVORAZIONE" keeps its own width and lets a sibling caption
            // truncate instead of the badge breaking onto a second line.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(style.background)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
