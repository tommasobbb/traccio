import SwiftUI

/// A pill-shaped filter control ("Tutti i conti" / "Categoria" in
/// `docs/design/canvas/Transactions.dc.html`) — a label with a trailing
/// chevron.
///
/// Built only from tokens already in `docs/design/tokens.md`: the pill
/// radius (999), `Palette.card`/`Palette.separator` for the resting state,
/// and the accent-vs-neutral convention `Badge.Style.accent` already uses
/// for `isActive`. Presentation only — the caller wraps it in a `Menu` or
/// whatever interaction it needs; a design-system component holds no logic
/// of its own.
struct FilterChip: View {
    let title: String
    /// Whether a non-default filter is currently applied. Tints the chip
    /// with the brand accent instead of the neutral surface, so an active
    /// filter stays visible even when its label alone ("Alimentari" instead
    /// of "Categoria") wouldn't say so.
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(isActive ? Palette.accent : Palette.ink)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Palette.accent : Palette.inkTertiary)
        }
        .padding(.leading, 13)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(isActive ? Palette.accent.opacity(0.12) : Palette.card)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(isActive ? Palette.accent.opacity(0.3) : Palette.separator)
        )
    }
}
