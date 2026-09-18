import SwiftUI
import TraccioCore

/// "Segna come anticipo" — the form presented from `TransactionDetailView`
/// for a transaction eligible to become an advance
/// (`TraccioCore.canBecomeAdvance(_:)`).
///
/// No mockup covers this (`docs/design/canvas/TransactionDetail.dc.html`
/// only shows the already-created case), so it is built from existing
/// tokens/components (`Card`, `EyebrowLabel`, `Banner`, `PillButton`) rather
/// than a new design pass — same posture as the category picker and the
/// transfer card. Presentational only: amounts are parsed here
/// (`TraccioCore.parseMoneyInput(_:)`) but never validated beyond "is this a
/// non-negative number" — the real range check
/// (`0 <= own_share <= |amount|`) is the backend's, which answers `422` with
/// a stable reason if it's wrong (`failureMessage` surfaces that as a
/// generic banner, per `.claude/rules/data-safety.md`: never a value in an
/// error).
struct CreateAdvanceSheet: View {
    /// The transaction this advance would be created on — its total is shown
    /// for reference and drives `equalSplit(total:ways:)`.
    let transaction: TransactionResponse
    var isCreating: Bool
    /// A generic failure message to show, or `nil` when there is none.
    var failureMessage: String?
    /// Called with the parsed own share (cents) and participants once the
    /// user submits a form with a valid own-share amount.
    let onCreate: (Int, [ParticipantRequest]) -> Void
    let onCancel: () -> Void

    @State private var ownShareText = ""
    @State private var participants: [Draft] = []

    /// One in-progress participant row. A local `Identifiable` wrapper, not
    /// `ParticipantRequest` itself, since the amount is edited as free text
    /// until submit parses it.
    private struct Draft: Identifiable {
        let id = UUID()
        var name = ""
        var amountText = ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    totalCard
                    ownShareCard
                    participantsCard
                }
                .padding(Spacing.gutter)
            }
            .sheetChrome("Segna come anticipo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea", action: submit)
                        .disabled(isCreating || parsedOwnShare == nil)
                }
            }
        }
    }

    // MARK: Total

    private var totalCard: some View {
        Card {
            EyebrowLabel(text: "Importo totale")
            AmountText(
                amount: transaction.amount, currencyCode: transaction.currency,
                kind: .spending, font: Typography.statFigure
            )
        }
    }

    // MARK: Own share

    private var ownShareCard: some View {
        Card {
            #if os(iOS)
                LabeledField(
                    eyebrow: "La tua quota", placeholder: "0,00", text: $ownShareText,
                    keyboardType: .decimalPad
                )
            #else
                LabeledField(eyebrow: "La tua quota", placeholder: "0,00", text: $ownShareText)
            #endif
            if !participants.isEmpty {
                PillButton(title: "Dividi in parti uguali", action: applyEqualSplit)
            }
        }
    }

    // MARK: Participants

    private var participantsCard: some View {
        Card {
            EyebrowLabel(text: "Partecipanti")
            ForEach($participants) { $draft in
                participantRow(draft: $draft)
                if draft.id != participants.last?.id {
                    Divider().overlay(Palette.separator)
                }
            }
            addParticipantRow
        }
    }

    private func participantRow(draft: Binding<Draft>) -> some View {
        HStack(spacing: Spacing.itemGap) {
            TextField("Nome", text: draft.name)
                .font(Typography.body)
            TextField("0,00", text: draft.amountText)
                #if os(iOS)
                    .keyboardType(.decimalPad)
                #endif
                .font(Typography.body)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Button {
                removeParticipant(id: draft.wrappedValue.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Palette.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rimuovi partecipante")
        }
        .padding(.vertical, 6)
    }

    private var addParticipantRow: some View {
        Button {
            participants.append(Draft())
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text("Aggiungi partecipante")
            }
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(Palette.accent)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func removeParticipant(id: UUID) {
        participants.removeAll { $0.id == id }
    }

    // MARK: Actions

    /// The own-share text field parsed to cents, or `nil` while it is empty
    /// or malformed — gates the "Crea" button, since the backend requires
    /// `own_share`.
    private var parsedOwnShare: Int? {
        TraccioCore.parseMoneyInput(ownShareText)
    }

    /// Prefill the own-share and every participant field with an even split
    /// of the transaction's total, editable afterwards. A no-op with no
    /// participants — nothing to split beyond the user's own full amount.
    private func applyEqualSplit() {
        let shares = TraccioCore.equalSplit(
            total: abs(transaction.amount), ways: participants.count + 1
        )
        guard let ownShare = shares.first else { return }
        ownShareText = Self.plainAmountText(cents: ownShare)
        for (index, share) in shares.dropFirst().enumerated() where index < participants.count {
            participants[index].amountText = Self.plainAmountText(cents: share)
        }
    }

    private func submit() {
        guard let ownShare = parsedOwnShare else { return }
        let resolvedParticipants = participants.compactMap { draft -> ParticipantRequest? in
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let amount = TraccioCore.parseMoneyInput(draft.amountText) else {
                return nil
            }
            return ParticipantRequest(name: name, expectedAmount: amount)
        }
        onCreate(ownShare, resolvedParticipants)
    }

    private static func plainAmountText(cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }
}
