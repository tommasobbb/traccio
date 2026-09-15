import SwiftUI
import TraccioCore

/// A closed Liquid Glass control (`docs/decisions/0030-liquid-glass-chrome.md`)
/// showing the current selection with its icon, opening an `OptionListCard`
/// sheet to change it. Replaces a bare `.pickerStyle(.menu)` for data-backed
/// options (accounts) that carry their own icon and colour — a native
/// `Picker`'s closed control shows neither.
struct SelectionSheet<Option: Identifiable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option.ID?
    let label: (Option) -> String
    let icon: (Option) -> (systemImage: String, color: PaletteColor)?
    /// Offered as a selectable row, and as the closed-control's placeholder
    /// text when nothing is picked yet. `nil` when a selection is always
    /// present (there is nothing to fall back to).
    var noneTitle: String?

    @State private var isPresented = false

    private var selectedOption: Option? {
        options.first { $0.id == selection }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                if let selectedOption, let glyph = icon(selectedOption) {
                    IconTile(systemImage: glyph.systemImage, color: glyph.color, diameter: 22)
                }
                Text(selectedOption.map(label) ?? noneTitle ?? "Scegli…")
                    .font(Typography.body)
                    .foregroundStyle(selectedOption == nil ? Palette.inkTertiary : Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                ScrollView {
                    OptionListCard {
                        if let noneTitle {
                            OptionRow(title: noneTitle, isSelected: selection == nil) {
                                selection = nil
                                isPresented = false
                            }
                        }
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            if index > 0 || noneTitle != nil {
                                Divider().overlay(Palette.separator)
                            }
                            OptionRow(
                                title: label(option),
                                icon: icon(option),
                                isSelected: selection == option.id
                            ) {
                                selection = option.id
                                isPresented = false
                            }
                        }
                    }
                    .padding(Spacing.gutter)
                }
                .sheetChrome(title)
            }
        }
    }
}
