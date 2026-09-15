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
    /// Whether the user's meal-vouchers setting is on (ADR 0029) — gates
    /// offering `.voucher` in the "Tipo" picker, same as
    /// `CreateManualAccountSheet`.
    var mealVouchersEnabled: Bool = false
    /// Called with the trimmed alias (`nil` to clear it), the chosen colour,
    /// the chosen icon, and the chosen kind once the user submits. `kind` is
    /// `nil` when the account is synced (no "Tipo" picker shown at all) or
    /// unchanged from `account.kind` — the caller only issues
    /// `POST /accounts/{id}/kind` when it is non-`nil` (ADR 0029: a synced
    /// account's kind is provider-derived, and a no-op write is pointless).
    let onSave: (String?, PaletteColor, AccountIcon, AccountKind?) -> Void
    /// Called when the user confirms deleting the account. `nil` for a synced
    /// account — only a manual one (ADR 0020) can be deleted here — so the
    /// affordance is simply absent otherwise. Also gates whether the "Tipo"
    /// picker shows at all: a synced account's kind is provider-derived.
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var aliasText: String
    @State private var color: PaletteColor
    @State private var icon: AccountIcon
    @State private var kind: AccountKind
    @State private var isConfirmingDelete = false

    private static let defaultColor = PaletteColor.slate
    private static let defaultIcon = AccountIcon.bank
    /// The kinds worth offering, same curated head as
    /// `CreateManualAccountSheet.offeredKinds` — kept in sync there rather
    /// than shared, the same "overkill for two call sites" call this file's
    /// colour/icon grids already make.
    private static let offeredKinds: [AccountKind] = [.cash, .wallet, .savings, .current, .card]

    init(
        account: AccountResponse,
        isSaving: Bool,
        failureMessage: String?,
        mealVouchersEnabled: Bool = false,
        onSave: @escaping (String?, PaletteColor, AccountIcon, AccountKind?) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.account = account
        self.isSaving = isSaving
        self.failureMessage = failureMessage
        self.mealVouchersEnabled = mealVouchersEnabled
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _aliasText = State(initialValue: account.alias ?? "")
        _color = State(initialValue: account.color ?? Self.defaultColor)
        _icon = State(initialValue: account.icon ?? Self.defaultIcon)
        _kind = State(initialValue: account.kind)
    }

    /// `offeredKinds` plus the account's own current kind (so an unusual
    /// existing kind, e.g. a manual "current", stays selectable) and
    /// `.voucher` when the setting is on. Order-preserving, no duplicates.
    private var kindOptions: [AccountKind] {
        var options = Self.offeredKinds
        if !options.contains(account.kind) { options.append(account.kind) }
        if mealVouchersEnabled, !options.contains(.voucher) { options.append(.voucher) }
        return options
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
                    if onDelete != nil {
                        Card {
                            EyebrowLabel(text: "Tipo")
                            Picker("Tipo", selection: $kind) {
                                ForEach(kindOptions, id: \.self) { candidate in
                                    Label(
                                        Self.label(for: candidate),
                                        systemImage: AccountIcon.default(for: candidate).systemImageName
                                    )
                                    .tag(candidate)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: kind) { _, newKind in
                                // Same light nudge as `CreateManualAccountSheet`:
                                // only replaces the icon while it is still at
                                // the account's own starting icon.
                                if newKind == .voucher, icon == (account.icon ?? Self.defaultIcon) {
                                    icon = .voucher
                                }
                            }
                        }
                    }
                    Card {
                        EyebrowLabel(text: "Colore")
                        colorGrid
                    }
                    Card {
                        EyebrowLabel(text: "Icona")
                        iconGrid
                    }
                    if onDelete != nil {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Text("Elimina conto")
                                .font(Typography.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.warning)
                        .disabled(isSaving)
                    }
                }
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Modifica conto")
            .confirmationDialog(
                "Eliminare \(account.displayName ?? "questo conto")?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Elimina", role: .destructive) { onDelete?() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("I movimenti del conto vanno eliminati prima. L'operazione non è reversibile.")
            }
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

    private static func label(for kind: AccountKind) -> String {
        switch kind {
        case .cash: "Contanti"
        case .wallet: "Wallet"
        case .savings: "Risparmio"
        case .current: "Corrente"
        case .card: "Carta"
        case .voucher: "Buoni pasto"
        }
    }

    private func submit() {
        onSave(trimmedAlias, color, icon, kind == account.kind ? nil : kind)
    }
}
