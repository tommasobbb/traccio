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
        .padding(20)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Palette.separatorSubtle, lineWidth: 1)
        )
        .shadow(color: Palette.cardShadow.opacity(0.04), radius: 1, x: 0, y: 1)
        .shadow(color: Palette.cardShadow.opacity(0.10), radius: 14, x: 0, y: 8)
    }
}
