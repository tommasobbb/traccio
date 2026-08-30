import SwiftUI
import TraccioCore

/// "Nuova categoria" / "Nuova sotto-categoria" / "Modifica categoria" — one
/// sheet for all three, since they differ only in title, prefill, and which
/// write they trigger on submit. Name, colour, and icon together — mirrors
/// `AccountEditorSheet`'s shape for the same reason: a full replace on
/// appearance, always both fields together.
struct CategoryEditorSheet: View {
    /// Which write this sheet performs. Modeled as an enum rather than an
    /// optional `CategoryResponse` plus a boolean flag, so "editing nothing"
    /// is unrepresentable (`.claude/rules/swift.md`).
    enum Mode {
        /// A new root (`parentID == nil`) or a new child of an existing root.
        case create(parentID: UUID?)
        case edit(CategoryResponse)
    }

    let mode: Mode
    var isSaving: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the trimmed name, colour, and icon once the user submits
    /// a valid form.
    let onSave: (String, PaletteColor, CategoryIcon?) -> Void
    let onCancel: () -> Void

    @State private var nameText = ""
    @State private var color: PaletteColor = .slate
    @State private var icon: CategoryIcon?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    Card {
                        EyebrowLabel(text: "Nome")
                        TextField("Es. Alimentari", text: $nameText)
                            .font(Typography.statFigure)
                            .foregroundStyle(Palette.ink)
                            .autocorrectionDisabled()
                    }
                    Card {
                        EyebrowLabel(text: "Colore")
                        colorGrid
                    }
                    Card {
                        EyebrowLabel(text: "Icona")
                        iconGrid
                    }
                }
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: submit)
                        .disabled(isSaving || trimmedName.isEmpty)
                }
            }
        }
        .onAppear {
            guard case .edit(let category) = mode, nameText.isEmpty else { return }
            nameText = category.name
            color = category.color
            icon = category.icon
        }
    }

    private var title: String {
        switch mode {
        case .create(let parentID): parentID == nil ? "Nuova categoria" : "Nuova sotto-categoria"
        case .edit: "Modifica categoria"
        }
    }

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName, color, icon)
    }

    private var colorGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(PaletteColor.allCases, id: \.self) { candidate in
                Button {
                    color = candidate
                } label: {
                    Circle()
                        .fill(Palette.color(candidate))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .strokeBorder(Palette.ink, lineWidth: candidate == color ? 2 : 0)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.rawValue)
                .accessibilityAddTraits(candidate == color ? .isSelected : [])
            }
        }
    }

    /// Sectioned so the ~55 icons stay scannable (a flat 5-column wall of
    /// tiles is not). The section titles and grouping are a presentation
    /// fact, defined next to the SF Symbol mapping in `CategoryIcon.pickerSections`.
    private var iconGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(CategoryIcon.pickerSections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(section.icons, id: \.self) { candidate in
                            Button {
                                icon = candidate
                            } label: {
                                IconTile(
                                    systemImage: candidate.systemImageName,
                                    color: color,
                                    diameter: 36
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                        .strokeBorder(
                                            Palette.ink, lineWidth: candidate == icon ? 2 : 0
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate.rawValue)
                            .accessibilityAddTraits(candidate == icon ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }
}
