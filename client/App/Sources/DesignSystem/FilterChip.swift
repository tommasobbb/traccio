import SwiftUI

/// A pill-shaped filter token — a label with a trailing glyph.
///
/// Used in Movimenti as a removable active-filter token (trailing `xmark`,
/// tap to clear that dimension). A caller that instead presents a menu can
/// pass `trailingSystemImage: "chevron.down"`.
///
/// A Liquid Glass capsule (`docs/decisions/0030-liquid-glass-chrome.md`) at
/// rest; `isActive` tints it with the accent — the one dose "Accent dosage"
/// (`docs/design/tokens.md`) allows a filter token, same rule as before, now
/// expressed as a glass tint instead of a flat `.opacity` fill. Presentation
/// only — the caller wraps it in a `Button` or whatever interaction it
/// needs; a design-system component holds no logic of its own.
struct FilterChip: View {
    let title: String
    /// Whether a non-default filter is currently applied. Tints the chip
    /// with the brand accent instead of the neutral surface, so an active
    /// filter stays visible even when its label alone ("Alimentari" instead
    /// of "Categoria") wouldn't say so.
    var isActive: Bool = false
    /// The trailing glyph. `xmark` (default) reads as "tap to remove".
    var trailingSystemImage: String = "xmark"

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(isActive ? Palette.accent : Palette.ink)
                // Never wrap (`docs/design/tokens.md`): a long active-filter
                // label ("Abbonamenti e servizi") keeps the chip on one line;
                // the row it sits in scrolls horizontally instead.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: trailingSystemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Palette.accent : Palette.inkTertiary)
        }
        .padding(.leading, 13)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .glassEffect(
            isActive ? .regular.tint(Palette.accent).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .sensoryFeedback(.selection, trigger: isActive)
    }
}
