import SwiftUI
import TraccioCore

/// "Modifica conto" — sets an account's alias, colour, and icon in one sheet
/// (ADR 0017). A full replace on colour/icon (both always submitted
/// together), mirroring `SetAccountAppearanceRequest`'s own shape.
struct AccountEditorSheet: View {
    let account: AccountResponse
    var isSaving: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the trimmed alias (`nil` to clear it), the chosen colour,
    /// and the chosen icon once the user submits.
    let onSave: (String?, PaletteColor, AccountIcon) -> Void
    let onCancel: () -> Void

    @State private var aliasText: String
    @State private var color: PaletteColor
    @State private var icon: AccountIcon

    private static let defaultColor = PaletteColor.slate
    private static let defaultIcon = AccountIcon.bank

    init(
        account: AccountResponse,
        isSaving: Bool,
        failureMessage: String?,
        onSave: @escaping (String?, PaletteColor, AccountIcon) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.account = account
        self.isSaving = isSaving
        self.failureMessage = failureMessage
        self.onSave = onSave
        self.onCancel = onCancel
        _aliasText = State(initialValue: account.alias ?? "")
        _color = State(initialValue: account.color ?? Self.defaultColor)
        _icon = State(initialValue: account.icon ?? Self.defaultIcon)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    Card {
                        EyebrowLabel(text: "Nome")
                        TextField(account.name ?? "Conto", text: $aliasText)
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
            .navigationTitle("Modifica conto")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: submit).disabled(isSaving)
                }
            }
        }
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

    private var iconGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(AccountIcon.allCases, id: \.self) { candidate in
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
                            .strokeBorder(Palette.ink, lineWidth: candidate == icon ? 2 : 0)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.rawValue)
                .accessibilityAddTraits(candidate == icon ? .isSelected : [])
            }
        }
    }

    private var trimmedAlias: String? {
        let trimmed = aliasText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func submit() {
        onSave(trimmedAlias, color, icon)
    }
}
