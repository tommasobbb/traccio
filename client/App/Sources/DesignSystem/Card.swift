import SwiftUI

/// The white, soft-shadowed container used for every grouping in the custom
/// UI (hero stats, connections, participants) — replaces `List`'s plain rows
/// per ADR 0008.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(Spacing.cardPadding)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separatorSubtle, lineWidth: 1)
        )
        // Two layers per `docs/design/tokens.md`: a tight near shadow and a
        // soft far one. `cardShadow` is opaque black; the opacity lives here.
        .shadow(color: Palette.cardShadow.opacity(0.04), radius: 1, x: 0, y: 1)
        .shadow(color: Palette.cardShadow.opacity(0.22), radius: 14, x: 0, y: 8)
    }
}
