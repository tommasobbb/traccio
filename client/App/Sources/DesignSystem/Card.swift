import SwiftUI

/// One of three elevation levels a `Card` (or a bespoke card-like container)
/// can sit at — ADR 0008's 2026-09-08 tone revision. `.flush` is a bordered
/// surface with no shadow (a group nested inside another card); `.resting` is
/// the everyday card with one soft shadow; `.raised` is the one card per
/// screen that genuinely floats — Panoramica's hero, a detail screen's
/// header. Since `docs/decisions/0032-glass-on-raised-cards.md`, `.raised`
/// is Liquid Glass rather than an opaque fill + shadow; `.flush`/`.resting`
/// are unchanged and stay opaque.
enum CardElevation {
    case flush
    case resting
    case raised

    var cornerRadius: CGFloat {
        self == .flush ? Radius.row : Radius.card
    }
}

extension View {
    /// Apply the shadow recipe for `elevation`. `.raised` carries no manual
    /// shadow of its own — it is glass now, and the system's own glass
    /// rendering already supplies the depth cue; stacking a flat-color
    /// shadow under a translucent surface read muddy. `.resting` keeps its
    /// one soft far layer; `.flush` has none and leans on its border.
    @ViewBuilder
    func cardElevationShadow(_ elevation: CardElevation) -> some View {
        switch elevation {
        case .flush, .raised:
            self
        case .resting:
            shadow(color: Palette.cardShadow.opacity(0.05), radius: 10, x: 0, y: 4)
        }
    }
}

/// The container used for every grouping in the custom UI (hero stats,
/// connections, participants) — replaces `List`'s plain rows per ADR 0008.
/// White and opaque at `.flush`/`.resting`; Liquid Glass at `.raised`
/// (`docs/decisions/0032-glass-on-raised-cards.md`) — the one card per
/// screen that floats now does so with material, not just a shadow.
///
/// `contentPadding` drops to `0` for a card that holds its own already-padded
/// rows with hairline dividers (a day group), so the rows meet the card edge
/// cleanly.
struct Card<Content: View>: View {
    var elevation: CardElevation = .resting
    var contentPadding: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if elevation == .raised {
                cardContent
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: elevation.cornerRadius, style: .continuous))
            } else {
                cardContent
                    .background(Palette.card)
                    .clipShape(RoundedRectangle(cornerRadius: elevation.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: elevation.cornerRadius, style: .continuous)
                            .strokeBorder(Palette.separatorSubtle, lineWidth: 1)
                    )
                    .cardElevationShadow(elevation)
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(contentPadding ?? Spacing.cardPadding)
    }
}
