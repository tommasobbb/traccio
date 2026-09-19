import SwiftUI
import TraccioCore

/// A bank's logo, in one of two shapes depending on where it appears.
///
/// The logo URL comes from Enable Banking's ASPSP `logo` (via
/// `InstitutionResponse.logo` / `ConnectionResponse.institutionLogo`) — a
/// wide wordmark, ~4.5:1 (`docs/openbanking.md`'s ~5431×1200 source), not a
/// square icon. `TraccioCore.institutionLogoURL` appends a resize transform
/// so the fetch is a couple of KB, not a multi-megapixel PNG.
struct BankLogoView: View {
    enum Style {
        /// A fixed square with the mark fitted inside via `scaledToFit` —
        /// squeezing a 4.5:1 wordmark into a square renders it a few points
        /// tall, so this is only right for a picker row's leading glyph
        /// (`StartConnectionSheet`), where every row needs the same fixed
        /// width regardless of the mark's own aspect ratio.
        case tile(size: CGFloat, cornerRadius: CGFloat? = nil)
        /// The mark at its own aspect ratio, left-aligned, at a given height
        /// — how a bank's own app shows its wordmark, and how Conti shows it
        /// now: the logo itself is the account/connection's title, not an
        /// icon beside one.
        case wordmark(height: CGFloat, maxWidth: CGFloat)
    }

    let logo: String?
    let name: String
    var style: Style = .tile(size: 40)

    var body: some View {
        switch style {
        case .tile(let size, let cornerRadius):
            tileBody(size: size, cornerRadius: cornerRadius ?? size * 0.3)
        case .wordmark(let height, let maxWidth):
            wordmarkBody(height: height, maxWidth: maxWidth)
        }
    }

    // MARK: Tile

    private func tileBody(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let url = TraccioCore.institutionLogoURL(logo, width: Int(size)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(size * 0.14)
                    case .empty:
                        SkeletonBlock(height: size, cornerRadius: cornerRadius)
                    case .failure:
                        lettermark(size: size)
                    @unknown default:
                        lettermark(size: size)
                    }
                }
            } else {
                lettermark(size: size)
            }
        }
        .frame(width: size, height: size)
        .background(Palette.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(name)
    }

    private func lettermark(size: CGFloat) -> some View {
        Text(name.first.map(String.init)?.uppercased() ?? "?")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Palette.inkSecondary)
    }

    // MARK: Wordmark

    /// Requests the logo at `maxWidth` (not the rendered height) — a
    /// wordmark's width is what determines the fetched image's own pixel
    /// budget, unlike the tile shape where the fixed square side does. Falls
    /// back to the institution's own name in `Typography.cardTitle`, exactly
    /// what Conti showed before this logo existed — no lettermark here, since
    /// a single letter reads as a broken tile at wordmark scale, not a
    /// deliberate fallback glyph.
    private func wordmarkBody(height: CGFloat, maxWidth: CGFloat) -> some View {
        Group {
            if let url = TraccioCore.institutionLogoURL(logo, width: Int(maxWidth)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .frame(height: height)
                            .padding(.horizontal, Spacing.tightGap)
                            .background(Palette.logoPlate)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    case .empty:
                        SkeletonBlock(width: maxWidth * 0.6, height: height, cornerRadius: Radius.tile)
                    case .failure:
                        nameFallback(height: height)
                    @unknown default:
                        nameFallback(height: height)
                    }
                }
            } else {
                nameFallback(height: height)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .accessibilityLabel(name)
    }

    private func nameFallback(height: CGFloat) -> some View {
        Text(name)
            .font(Typography.cardTitle)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .frame(minHeight: height, alignment: .leading)
    }
}
