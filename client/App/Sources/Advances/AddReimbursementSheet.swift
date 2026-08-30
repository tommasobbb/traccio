import SwiftUI
import TraccioCore

/// "Aggiungi rimborso" — the form presented from `AdvanceSections` to
/// register a reimbursement against an advance, either a manual cash entry
/// or a link to an incoming transaction, and optionally attributed to one
/// participant (ADR 0012).
///
/// The flow reads top-to-bottom in the order the user actually decides: pick
/// the movement first, and its magnitude prefills the amount
/// (`TraccioCore.reimbursementAmountInput(forLinked:)`) — the field stays
/// editable, because a reimbursement amount is deliberately never validated
/// against an expected share (`docs/domain.md` §Reimbursement: one transfer
/// may cover two people, or arrive rounded). "Nessuno — contanti" clears it
/// again and the amount is typed by hand, as for a cash entry.
///
/// No mockup covers the form itself
/// (`docs/design/canvas/TransactionDetail.dc.html` only shows the button),
/// so it is built from existing tokens/components — same posture as
/// `CreateAdvanceSheet`. `candidates` is best-effort
/// (`TransactionDetailViewModel.loadReimbursementCandidatesIfNeeded()`): an
/// empty list still lets the sheet work, just as a cash-only entry.
/// `accountsByID` is best-effort too — a candidate whose account is missing
/// falls back to a generic label, it never hides the row. `participants`
/// comes straight from the advance already held by the caller — no extra
/// fetch, and never stale relative to what the "Partecipanti" card on
/// `AdvanceSections` shows.
struct AddReimbursementSheet: View {
    /// Transactions eligible to be linked (already filtered to `personal`,
    /// incoming, the advance's currency).
    let candidates: [TransactionResponse]
    /// Account id → account, for a candidate row's destination account name
    /// and colour dot. Best-effort: a missing entry degrades to "Conto".
    let accountsByID: [UUID: AccountResponse]
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
                    if !candidates.isEmpty {
                        linkCard
                    }
                    amountCard
                    if !participants.isEmpty {
                        participantCard
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

    // MARK: Link

    private var linkCard: some View {
        Card {
            EyebrowLabel(text: "Collega a un movimento")
            Button {
                select(nil)
            } label: {
                cashRow(isSelected: selectedTransactionID == nil)
            }
            .buttonStyle(.plain)
            ForEach(candidates) { candidate in
                Divider().overlay(Palette.separator)
                Button {
                    select(candidate)
                } label: {
                    candidateRow(candidate, isSelected: selectedTransactionID == candidate.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Set the linked transaction and pull its magnitude into the amount
    /// field, so the common case (link a movement, the amount is exactly its
    /// value) needs no typing. Re-selecting overwrites — the latest choice
    /// always wins, so a stale prefilled amount can't linger.
    private func select(_ transaction: TransactionResponse?) {
        selectedTransactionID = transaction?.id
        amountText = TraccioCore.reimbursementAmountInput(forLinked: transaction)
    }

    private func cashRow(isSelected: Bool) -> some View {
        HStack {
            Text("Nessuno — contanti")
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func candidateRow(_ candidate: TransactionResponse, isSelected: Bool) -> some View {
        let account = accountsByID[candidate.accountID]
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.displayDescription ?? candidate.description)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let date = candidate.effectiveDate {
                        Text(Self.formatRowDate(date))
                    }
                    Text("·")
                    Circle()
                        .fill(Palette.color(account?.tileColor ?? .slate))
                        .frame(width: 6, height: 6)
                    Text(account?.displayName ?? "Conto")
                        .lineLimit(1)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                AmountText(
                    amount: candidate.amount,
                    currencyCode: candidate.currency,
                    kind: .income,
                    font: Typography.body.weight(.semibold)
                )
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            if let mismatchNote {
                Text(mismatchNote)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    /// A quiet note when the typed amount no longer matches the linked
    /// movement's value — a legitimate case (one transfer covering two
    /// shares), so it informs rather than blocks.
    private var mismatchNote: String? {
        guard
            let selectedTransactionID,
            let linked = candidates.first(where: { $0.id == selectedTransactionID }),
            let parsedAmount,
            parsedAmount != abs(linked.amount)
        else { return nil }
        return "Diverso dall'importo del movimento collegato ("
            + TraccioCore.formatMoney(amount: abs(linked.amount), currencyCode: linked.currency)
            + ")."
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

    /// Build the formatter locally per call rather than share a mutable
    /// static — the `Sendable` posture `.claude/rules/swift.md` asks for, and
    /// what `TransactionsView.title(for:)` already does for its day headers.
    private static func formatRowDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return formatter.string(from: date)
    }

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
