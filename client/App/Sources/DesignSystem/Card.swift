import SwiftUI

/// One of three elevation levels a `Card` (or a bespoke card-like container)
/// can sit at — ADR 0008's 2026-09-08 tone revision. `.flush` is a bordered
/// surface with no shadow (a group nested inside another card); `.resting` is
/// the everyday card with one soft shadow; `.raised` keeps the deeper
/// two-layer shadow for something that genuinely floats — Panoramica's hero
/// card (the only `.raised` on that screen, so it reads as the protagonist
/// without a colour band), or an active sheet. Liquid Glass on `.raised` was
/// tried and rejected on device — see `docs/decisions/0032-glass-on-raised-cards.md`.
enum CardElevation {
    case flush
    case resting
    case raised

    var cornerRadius: CGFloat {
        self == .flush ? Radius.row : Radius.card
    }
}

extension View {
    /// Apply the shadow recipe for `elevation`. `.raised` is the two-layer
    /// near+far from `docs/design/tokens.md`; `.resting` is one soft far
    /// layer; `.flush` has none and leans on its border.
    @ViewBuilder
    func cardElevationShadow(_ elevation: CardElevation) -> some View {
        switch elevation {
        case .flush:
            self
        case .resting:
            shadow(color: Palette.cardShadow.opacity(0.05), radius: 10, x: 0, y: 4)
        case .raised:
            shadow(color: Palette.cardShadow.opacity(0.04), radius: 1, x: 0, y: 1)
                .shadow(color: Palette.cardShadow.opacity(0.22), radius: 14, x: 0, y: 8)
        }
    }
}

/// The white, soft-shadowed container used for every grouping in the custom
/// UI (hero stats, connections, participants) — replaces `List`'s plain rows
/// per ADR 0008.
///
/// `contentPadding` drops to `0` for a card that holds its own already-padded
/// rows with hairline dividers (a day group), so the rows meet the card edge
/// cleanly.
struct Card<Content: View>: View {
    var elevation: CardElevation = .resting
    var contentPadding: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cardSectionGap) {
            content
        }
        .padding(contentPadding ?? Spacing.cardPadding)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: elevation.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: elevation.cornerRadius, style: .continuous)
                .strokeBorder(Palette.separatorSubtle, lineWidth: 1)
        )
        .cardElevationShadow(elevation)
    }
}
