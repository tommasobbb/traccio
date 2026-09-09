import SwiftUI
import TraccioCore

/// The leading tile for an event — its emoji on a soft wash of its colour,
/// or, when no emoji is set, an `IconTile` calendar glyph (ADR 0027).
///
/// Two anatomies, each deliberate:
/// - **with emoji** — a pale fill (`Palette.color(...)` at low opacity) with
///   a hairline border and the emoji centred. The opacity rides on an
///   already theme-dynamic colour, so it resolves in both appearances (the
///   `Palette.separator` technique). The tone pass rejected a pale fill under
///   a *thin coloured glyph* as muddy; an emoji is its own colour, and an
///   emoji on a *saturated* fill is unreadable — so the wash is the right
///   ground here specifically.
/// - **without emoji** — the standard `IconTile`: solid `PaletteColor` fill,
///   white `calendar` glyph. This is the fallback; the editor offers a
///   default emoji, so most events land in the first case.
struct EventTile: View {
    /// The event's emoji, or `nil` for the calendar fallback.
    let emoji: String?
    /// The event's colour; `nil` uses the neutral default (`.slate`).
    let color: PaletteColor?
    var diameter: CGFloat = 32

    private var resolvedColor: PaletteColor { color ?? .slate }

    var body: some View {
        if let emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: diameter * 0.5))
                .frame(width: diameter, height: diameter)
                .background(Palette.color(resolvedColor).opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(Palette.color(resolvedColor).opacity(0.32), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .accessibilityHidden(true)
        } else {
            IconTile(systemImage: "calendar", color: resolvedColor, diameter: diameter)
        }
    }
}
