import SwiftUI
import TraccioCore

/// "Aggiungi rimborso" — the form presented from `AdvanceSections` to
/// register a reimbursement against an advance, either a manual cash entry
/// or a link to an incoming transaction, and optionally attributed to one
/// participant (ADR 0012).
///
/// No mockup covers the form itself
/// (`docs/design/canvas/TransactionDetail.dc.html` only shows the button),
/// so it is built from existing tokens/components — same posture as
/// `CreateAdvanceSheet`. `candidates` is best-effort
/// (`TransactionDetailViewModel.loadReimbursementCandidatesIfNeeded()`): an
/// empty list still lets the sheet work, just as a cash-only entry.
/// `participants` comes straight from the advance already held by the
/// caller — no extra fetch, and never stale relative to what the "Partecipanti"
/// card on `AdvanceSections` shows.
struct AddReimbursementSheet: View {
    /// Transactions eligible to be linked (already filtered to `personal`,
    /// incoming, the advance's currency).
    let candidates: [TransactionResponse]
    /// The advance's participants, for the "who does this belong to" picker
    /// (ADR 0012). Empty when the advance has none, or when the lookup
    /// hasn't resolved — the card simply doesn't appear (same degrade as
    /// `linkCard` for an empty `candidates`).
    let participants: [ParticipantResponse]
    var isCreating: Bool
    /// A generic failure message to show, or `nil` when there is none.
    var failureMessage: String?
    /// Called with the completed draft on submit.
    let onCreate: (ReimbursementDraft) -> Void
    let onCancel: () -> Void

    @State private var amountText = ""
    @State private var noteText = ""
    @State private var selectedTransactionID: UUID?
    @State private var selectedParticipantID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    amountCard
                    if !participants.isEmpty {
                        participantCard
                    }
                    if !candidates.isEmpty {
                        linkCard
                    }
                    noteCard
                }
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Aggiungi rimborso")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: submit)
                        .disabled(isCreating || parsedAmount == nil)
                }
            }
        }
    }

    // MARK: Amount

    private var amountCard: some View {
        Card {
            EyebrowLabel(text: "Importo ricevuto")
            TextField("0,00", text: $amountText)
                #if os(iOS)
                    .keyboardType(.decimalPad)
                #endif
                .font(Typography.statFigure)
                .foregroundStyle(Palette.ink)
        }
    }

    // MARK: Participant

    private var participantCard: some View {
        Card {
            EyebrowLabel(text: "Partecipante")
            Button {
                selectedParticipantID = nil
            } label: {
                candidateRow(title: "Non specificato", isSelected: selectedParticipantID == nil)
            }
            .buttonStyle(.plain)
            ForEach(participants) { participant in
                Divider().overlay(Palette.separator)
                Button {
                    selectedParticipantID = participant.id
                } label: {
                    candidateRow(
                        title: participant.name,
                        isSelected: selectedParticipantID == participant.id
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Link

    private var linkCard: some View {
        Card {
            EyebrowLabel(text: "Collega a un movimento")
            Button {
                selectedTransactionID = nil
            } label: {
                candidateRow(title: "Nessuno — contanti", isSelected: selectedTransactionID == nil)
            }
            .buttonStyle(.plain)
            ForEach(candidates) { candidate in
                Divider().overlay(Palette.separator)
                Button {
                    selectedTransactionID = candidate.id
                } label: {
                    candidateRow(
                        title: candidate.displayDescription ?? candidate.description,
                        isSelected: selectedTransactionID == candidate.id
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func candidateRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Note

    private var noteCard: some View {
        Card {
            EyebrowLabel(text: "Nota (opzionale)")
            TextField("Es. Marco via bonifico", text: $noteText)
                .font(Typography.body)
        }
    }

    // MARK: Submit

    private var parsedAmount: Int? {
        TraccioCore.parseMoneyInput(amountText)
    }

    private func submit() {
        guard let amount = parsedAmount else { return }
        let trimmedNote = noteText.trimmingCharacters(in: .whitespaces)
        onCreate(
            ReimbursementDraft(
                amount: amount,
                participantID: selectedParticipantID,
                transactionID: selectedTransactionID,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
        )
    }
}
