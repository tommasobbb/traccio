import SwiftUI

/// A centered icon, title, and optional description/action — the custom
/// replacement for SwiftUI's stock `ContentUnavailableView`, which every
/// full-screen empty/failed state used until now despite ADR 0008's "not
/// stock" direction: its system-styled icon and type broke the card-based
/// look everywhere it appeared.
///
/// Covers both shapes a screen needs: "nothing here yet" (`tone: .neutral`,
/// no action) and "couldn't load" (`tone: .warning`, usually with a retry
/// action) — the two were previously built ad hoc per screen with duplicated
/// copy ("Verifica che il backend sia in esecuzione, poi riprova.").
struct EmptyState: View {
    enum Tone {
        /// Nothing to show yet — a quiet, informational state.
        case neutral
        /// A failed load — the same warning tone as the consent-expiry
        /// banner, since both mean "something needs attention."
        case warning

        var iconForeground: Color {
            switch self {
            case .neutral: Palette.inkTertiary
            case .warning: Palette.warning
            }
        }

        var iconBackground: Color {
            switch self {
            case .neutral: Palette.neutralFill
            case .warning: Palette.warningTint
            }
        }
    }

    let systemImage: String
    let title: String
    var description: String?
    var tone: Tone = .neutral
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.itemGap) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(tone.iconForeground)
                .frame(width: 56, height: 56)
                .background(tone.iconBackground)
                .clipShape(Circle())

            Text(title)
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)

            if let description {
                Text(description)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                PillButton(title: actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}
