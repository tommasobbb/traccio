import SwiftUI
import TraccioCore

/// The card + row pair behind every static option list in a sheet (Movimenti's
/// filter sheet, the account picker in the manual-transaction/import sheets)
/// — a bordered container with hairline-divided rows, a checkmark on the
/// selected one, and an `IconTile` when the option carries its own icon.
/// Extracted from `TransactionFiltersSheet`'s private `optionCard`/`optionRow`
/// so any other picker-shaped sheet reuses the same look instead of
/// re-implementing it.
struct OptionListCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(Palette.separatorSubtle)
            )
    }
}

/// One row inside an `OptionListCard`: a title, an optional leading glyph,
/// and a trailing checkmark when selected.
struct OptionRow: View {
    let title: String
    /// The option's own icon and colour (an account, a category) — takes
    /// priority over `swatch`. `nil` for an option with no icon concept
    /// ("Tutti i conti", "Tutte le categorie").
    var icon: (systemImage: String, color: PaletteColor)?
    /// A bare colour swatch, for a caller with a colour but no icon.
    var swatch: Color?
    var isSelected: Bool
    /// Indents the row one level, for a category's child under its parent.
    var indented: Bool = false
    let action: () -> Void

    var body: some View {
        OptionRowLayout(title: title, isSelected: isSelected, indented: indented, action: action) {
            if let icon {
                IconTile(systemImage: icon.systemImage, color: icon.color, diameter: 24)
            } else if let swatch {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(swatch)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

/// The shared skeleton behind `OptionRow` — title, spacer, trailing
/// checkmark, `.pressableRow` feedback — with the leading glyph left open as
/// a generic `@ViewBuilder` so a caller whose option carries something
/// `OptionRow`'s `icon`/`swatch` pair can't express (an event's `EventTile`
/// emoji wash, ADR 0027) still gets the same row DNA instead of
/// reimplementing it. `EventPickerSheet` is the one call site so far that
/// needs this directly; everything else goes through `OptionRow`.
struct OptionRowLayout<Leading: View>: View {
    let title: String
    var isSelected: Bool
    var indented: Bool = false
    let action: () -> Void
    @ViewBuilder let leading: Leading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.leading, indented ? 34 : 14)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}
