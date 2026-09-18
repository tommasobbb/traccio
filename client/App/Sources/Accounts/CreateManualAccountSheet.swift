import SwiftUI
import TraccioCore

/// "Nuovo conto manuale" — creates an account with no bank behind it
/// (ADR 0020): a cash float ("Contanti"), an investment pass-through. The
/// user names it, picks what kind it is and its currency, and optionally an
/// appearance. Mirrors `AccountEditorSheet`'s card layout; the colour/icon
/// grids are the same controls, lifted into a small shared helper would be
/// overkill for two call sites, so they are re-expressed here.
struct CreateManualAccountSheet: View {
    var isSaving: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Whether the user's meal-vouchers setting is on (ADR 0029) — gates
    /// offering `.voucher` in the "Tipo" picker; off by default for most
    /// users, so the kind stays hidden until they turn the feature on.
    var mealVouchersEnabled: Bool = false
    /// Called with the trimmed alias, kind, uppercased currency, and the
    /// chosen colour/icon (`nil` when left on the neutral default) once the
    /// user submits.
    let onCreate: (String, AccountKind, String, PaletteColor?, AccountIcon?) -> Void
    let onCancel: () -> Void

    @State private var aliasText = ""
    @State private var kind: AccountKind = .cash
    @State private var currencyText = "EUR"
    @State private var color: PaletteColor = .slate
    @State private var icon: AccountIcon = .cash

    /// The kinds worth offering for a hand-tracked account, most likely
    /// first. The backend accepts any `AccountKind`, but a manual "current"
    /// or "card" is unusual enough not to clutter the picker's head.
    private static let offeredKinds: [AccountKind] = [.cash, .wallet, .savings, .current, .card]

    /// `offeredKinds`, plus `.voucher` when the setting is on. A computed
    /// property, not a stored one — `offeredKinds` stays a fixed list a
    /// `Picker` binding can key off directly at rest.
    private var kindOptions: [AccountKind] {
        mealVouchersEnabled ? Self.offeredKinds + [.voucher] : Self.offeredKinds
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    Card {
                        LabeledField(eyebrow: "Nome", placeholder: "Contanti", text: $aliasText)
                    }
                    Card {
                        EyebrowLabel(text: "Tipo")
                        // `.menu`, not `.segmented`: six candidates with the
                        // meal-vouchers kind offered no longer fit a
                        // segmented control on an iPhone-width sheet.
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
                            // A light nudge, not a hard rule: only replaces
                            // the icon while it is still at the sheet's
                            // neutral default, never a colour/icon the user
                            // already customized.
                            if newKind == .voucher, icon == Self.defaultIcon {
                                icon = .voucher
                            }
                        }
                    }
                    Card {
                        #if os(iOS)
                            LabeledField(
                                eyebrow: "Valuta", placeholder: "EUR", text: $currencyText,
                                autocapitalization: .characters
                            )
                            .onChange(of: currencyText) { _, newValue in
                                currencyText = String(newValue.uppercased().prefix(3))
                            }
                        #else
                            LabeledField(eyebrow: "Valuta", placeholder: "EUR", text: $currencyText)
                                .onChange(of: currencyText) { _, newValue in
                                    currencyText = String(newValue.uppercased().prefix(3))
                                }
                        #endif
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
                .padding(Spacing.gutter)
            }
            .sheetChrome("Nuovo conto manuale")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea", action: submit).disabled(isSaving || !canSubmit)
                }
            }
        }
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

    private var trimmedAlias: String {
        aliasText.trimmingCharacters(in: .whitespaces)
    }

    private var canSubmit: Bool {
        !trimmedAlias.isEmpty && currencyText.count == 3
    }

    private func submit() {
        onCreate(
            trimmedAlias,
            kind,
            currencyText,
            color == Self.defaultColor ? nil : color,
            icon == Self.defaultIcon ? nil : icon
        )
    }

    private static let defaultColor = PaletteColor.slate
    private static let defaultIcon = AccountIcon.cash

    private var colorGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.itemGap), count: 5)
        return LazyVGrid(columns: columns, spacing: Spacing.itemGap) {
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
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.itemGap), count: 5)
        return LazyVGrid(columns: columns, spacing: Spacing.itemGap) {
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
}
