import SwiftUI
import TraccioCore

/// "Nuovo movimento" — records a hand-entered movement on a manual account
/// (ADR 0020). Only manual accounts are offered: a synced account's history
/// is bank-owned. The amount is typed as a plain positive number and signed
/// by the Spesa/Entrata toggle, mirroring `CreateAdvanceSheet`'s
/// `parseMoneyInput` approach rather than a numeric binding.
struct CreateManualTransactionSheet: View {
    /// The manual accounts the movement can belong to. Empty means the
    /// caller has no manual account yet — the sheet then shows guidance
    /// instead of a broken picker.
    let accounts: [AccountResponse]
    var isCreating: Bool
    var failureMessage: String?
    /// Called with the signed amount (minor units), currency, value date, and
    /// description once the user submits.
    let onCreate: (_ accountID: UUID, _ amount: Int, _ currency: String, _ valueDate: Date, _ description: String) -> Void
    let onCancel: () -> Void

    @State private var selectedAccountID: UUID?
    @State private var direction: Direction = .out
    @State private var amountText = ""
    @State private var valueDate = Date()
    @State private var descriptionText = ""

    private enum Direction: Hashable {
        case out
        case `in`
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    if accounts.isEmpty {
                        Card {
                            EyebrowLabel(text: "Nessun conto manuale")
                            Text(
                                "Crea prima un conto manuale in Conti per registrare un movimento a mano."
                            )
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                        }
                    } else {
                        formCards
                    }
                }
                .padding(Spacing.gutter)
            }
            .sheetChrome("Nuovo movimento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aggiungi", action: submit).disabled(isCreating || !canSubmit)
                }
            }
        }
        .onAppear {
            if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
        }
    }

    @ViewBuilder
    private var formCards: some View {
        Card {
            EyebrowLabel(text: "Conto")
            SelectionSheet(
                title: "Conto",
                options: accounts,
                selection: $selectedAccountID,
                label: { $0.displayName ?? "Conto" },
                icon: { ($0.tileIcon.systemImageName, $0.tileColor) }
            )
        }
        Card {
            EyebrowLabel(text: "Tipo")
            Picker("Tipo", selection: $direction) {
                Text("Spesa").tag(Direction.out)
                Text("Entrata").tag(Direction.in)
            }
            .pickerStyle(.segmented)
            .segmentedPickerTint()
        }
        Card {
            #if os(iOS)
                LabeledField(
                    eyebrow: "Importo (\(selectedCurrency))", placeholder: "0,00", text: $amountText,
                    keyboardType: .decimalPad
                )
            #else
                LabeledField(eyebrow: "Importo (\(selectedCurrency))", placeholder: "0,00", text: $amountText)
            #endif
        }
        Card {
            EyebrowLabel(text: "Data")
            DatePicker("Data", selection: $valueDate, displayedComponents: .date)
                .labelsHidden()
        }
        Card {
            LabeledField(
                eyebrow: "Descrizione", placeholder: "Es. Spesa supermercato", text: $descriptionText,
                font: Typography.body
            )
        }
    }

    private var selectedAccount: AccountResponse? {
        accounts.first { $0.id == selectedAccountID }
    }

    private var selectedCurrency: String {
        selectedAccount?.currency ?? "EUR"
    }

    private var parsedAmount: Int? {
        guard let magnitude = TraccioCore.parseMoneyInput(amountText), magnitude > 0 else {
            return nil
        }
        return direction == .out ? -magnitude : magnitude
    }

    private var trimmedDescription: String {
        descriptionText.trimmingCharacters(in: .whitespaces)
    }

    private var canSubmit: Bool {
        selectedAccountID != nil && parsedAmount != nil && !trimmedDescription.isEmpty
    }

    private func submit() {
        guard let accountID = selectedAccountID, let amount = parsedAmount else { return }
        onCreate(accountID, amount, selectedCurrency, valueDate, trimmedDescription)
    }
}
