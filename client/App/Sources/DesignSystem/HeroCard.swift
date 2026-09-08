import SwiftUI

/// A card whose header sits on a filled forest-green band and whose body sits
/// on card white — one rounded, bordered, shadowed container, sharing `Card`'s
/// radius, border and two-layer shadow so the two read as one family.
///
/// Panoramica's hero uses it so the brand colour has real presence on the
/// first screen the app opens
/// (`docs/decisions/0008-client-design-direction.md`, 2026-09-07 revision).
/// The band is its own `heroFill`/`heroFillDeep` colorset — deep forest in
/// both appearances — with `onHero` inks, since the dark accent is a light
/// mint that white text would not read on.
struct HeroCard<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.cardPadding)
            .background(
                LinearGradient(
                    colors: [Palette.heroFill, Palette.heroFillDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.cardPadding)
            .background(Palette.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separatorSubtle, lineWidth: 1)
        )
        .cardElevationShadow(.raised)
    }
}
