import SwiftUI
import TraccioCore

/// "Modifica movimento" — edits a hand-entered movement on a manual account
/// (ADR 0020). Same fields as `CreateManualTransactionSheet` minus the
/// account (a movement does not move between accounts) and category
/// (`TransactionDetailView`'s own picker owns that). Prefilled from the row.
struct EditManualTransactionSheet: View {
    let transaction: TransactionResponse
    var isSaving: Bool
    var failureMessage: String?
    /// Called with the signed amount (minor units), currency, value date, and
    /// description once the user submits.
    let onSave: (_ amount: Int, _ currency: String, _ valueDate: Date, _ description: String) -> Void
    let onCancel: () -> Void

    @State private var direction: Direction
    @State private var amountText: String
    @State private var valueDate: Date
    @State private var descriptionText: String

    private enum Direction: Hashable {
        case out
        case `in`
    }

    init(
        transaction: TransactionResponse,
        isSaving: Bool,
        failureMessage: String?,
        onSave: @escaping (Int, String, Date, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.isSaving = isSaving
        self.failureMessage = failureMessage
        self.onSave = onSave
        self.onCancel = onCancel
        _direction = State(initialValue: transaction.amount < 0 ? .out : .in)
        let magnitude = abs(transaction.amount)
        _amountText = State(initialValue: "\(magnitude / 100),\(String(format: "%02d", magnitude % 100))")
        _valueDate = State(initialValue: transaction.valueDate ?? transaction.bookedAt ?? Date())
        _descriptionText = State(
            initialValue: transaction.displayDescription ?? transaction.description
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    Card {
                        EyebrowLabel(text: "Tipo")
                        Picker("Tipo", selection: $direction) {
                            Text("Spesa").tag(Direction.out)
                            Text("Entrata").tag(Direction.in)
                        }
                        .pickerStyle(.segmented)
                    }
                    Card {
                        EyebrowLabel(text: "Importo (\(transaction.currency))")
                        TextField("0,00", text: $amountText)
                            .font(Typography.statFigure)
                            .foregroundStyle(Palette.ink)
                            #if os(iOS)
                                .keyboardType(.decimalPad)
                            #endif
                    }
                    Card {
                        EyebrowLabel(text: "Data")
                        DatePicker("Data", selection: $valueDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                    Card {
                        EyebrowLabel(text: "Descrizione")
                        TextField("Descrizione", text: $descriptionText)
                            .font(Typography.body)
                            .foregroundStyle(Palette.ink)
                            .autocorrectionDisabled()
                    }
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Modifica movimento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: submit).disabled(isSaving || !canSubmit)
                }
            }
        }
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
        parsedAmount != nil && !trimmedDescription.isEmpty
    }

    private func submit() {
        guard let amount = parsedAmount else { return }
        onSave(amount, transaction.currency, valueDate, trimmedDescription)
    }
}
