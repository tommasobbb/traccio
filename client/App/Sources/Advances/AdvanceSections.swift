import SwiftUI
import TraccioCore

/// The advance-specific cards on `TransactionDetailView`: the split, the
/// participants, the reimbursements, and (unlink/write-off/reopen/add) the
/// actions on them — rendered only for a transaction whose advance resolved.
///
/// Every displayed value still arrives via `init`, never recomputed here
/// (`client/CLAUDE.md`: the backend owns every derived value;
/// `receivable`/`reimbursed`/`outstanding`/`excess` are `AdvanceResponse`
/// fields). The actions, though, are no longer presentational-only: this view
/// owns the confirmation-dialog state for the two destructive ones (unlink,
/// write-off) and calls back up to `TransactionDetailViewModel` through
/// plain closures, same shape as `TransferSection.onUnlink`.
///
/// Follows `docs/design/canvas/TransactionDetail.dc.html`. The event chip it
/// also shows now lives one level up, on `TransactionDetailView`'s own body
/// (it applies to any transaction, not just an advance one). Per-participant
/// reimbursement status ("Marco — Rimborsato" / "Giulia — In attesa") is
/// built from `ParticipantResponse.status` (ADR 0012) — the mockup element
/// this file used to be unable to support honestly, now that a
/// `Reimbursement` can attribute itself to one `Participant`. The
/// reimbursements card also lists each recorded reimbursement individually,
/// with a per-row delete — `GET`/`DELETE /advances/{id}/reimbursements` had
/// no client caller until this list existed.
struct AdvanceSections: View {
    let transaction: TransactionResponse
    let advance: AdvanceResponse
    /// The advance's recorded reimbursements, for the per-row list. Loading
    /// and failure states are shown quietly — the summary figures above
    /// already come straight off `advance`, not off this list.
    let reimbursements: TransactionDetailViewModel.ReimbursementsState
    /// Set while a delete/write-off/reopen/reimbursement is in flight, to
    /// disable the actions here.
    var isUpdating: Bool = false
    /// Called after the destructive confirmation, to delete this advance and
    /// revert the transaction to `personal`.
    let onUnlink: () -> Void
    /// Called after the destructive confirmation, to write off this advance.
    let onWriteOff: () -> Void
    /// Called to reopen a previously written-off advance. No confirmation —
    /// reopening only restores visibility into an amount still outstanding,
    /// nothing is lost.
    let onReopen: () -> Void
    /// Called to present `AddReimbursementSheet`.
    let onAddReimbursement: () -> Void
    /// Called after the destructive confirmation, to delete one recorded
    /// reimbursement.
    let onDeleteReimbursement: (ReimbursementResponse) -> Void

    @State private var isConfirmingUnlink = false
    @State private var isConfirmingWriteOff = false
    /// The reimbursement pending a destructive confirmation, if any —
    /// `.confirmationDialog(item:)` needs the row itself, not just a `Bool`,
    /// since the dialog's message depends on whether it links a transaction.
    @State private var reimbursementPendingDeletion: ReimbursementResponse?

    var body: some View {
        splitCard
        participantsCard
        reimbursementsCard
        reimbursementActionsRow
        unlinkRow
    }

    // MARK: Split

    private var splitCard: some View {
        Card {
            EyebrowLabel(text: "Anticipo · la tua quota")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Importo totale")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                    Text(TraccioCore.formatMoney(amount: abs(transaction.amount), currencyCode: advance.currency))
                        .font(Typography.compactFigure)
                        .foregroundStyle(Palette.inkTertiary)
                        .strikethrough(color: Palette.inkTertiary.opacity(0.5))
                }
                Spacer()
                AmountText(
                    amount: -advance.ownShare,
                    currencyCode: advance.currency,
                    kind: .spending,
                    font: Typography.heroFigure
                )
            }
            splitBar
            Text("Diviso in \(splitCount)")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private var splitCount: Int {
        advance.participants.count + 1
    }

    /// The first segment is your own quota; the rest are the other
    /// participants. Ink, not accent — this is a data figure, not a control
    /// (`docs/design/tokens.md`'s "Accent dosage").
    private var splitBar: some View {
        HStack(spacing: 3) {
            ForEach(0..<splitCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index == 0 ? Palette.ink : Palette.neutralFill)
                    .frame(height: 10)
            }
        }
    }

    // MARK: Participants

    private var participantsCard: some View {
        Card {
            EyebrowLabel(text: "Partecipanti")
            participantRow(
                name: "Tu", amount: advance.ownShare,
                caption: .own("Quota propria — nessun rimborso dovuto")
            )
            ForEach(advance.participants) { participant in
                Divider().overlay(Palette.separator)
                participantRow(
                    name: participant.name, amount: participant.expectedAmount,
                    caption: .status(participant.status)
                )
            }
        }
    }

    /// A participant row's caption: either the fixed neutral note on the
    /// "Tu" row, or a real participant's derived reimbursement status
    /// (ADR 0012) — two different things that happen to occupy the same
    /// slot, not variants of one concept.
    private enum ParticipantCaption {
        case own(String)
        case status(ParticipantStatus)
    }

    private func participantRow(name: String, amount: Int, caption: ParticipantCaption) -> some View {
        HStack(spacing: 12) {
            avatar(for: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                participantCaption(caption)
            }
            Spacer()
            Text(TraccioCore.formatMoney(amount: amount, currencyCode: advance.currency))
                .font(Typography.body.weight(.bold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
    }

    /// Renders `docs/design/canvas/TransactionDetail.dc.html`'s
    /// `.p-status.done`/`.p-status.pending` — a small icon plus label, tinted
    /// with the exact colors the mockup uses (`SummaryTint.income`/
    /// `.warning`, already the palette's own semantic tones, not new ones).
    @ViewBuilder
    private func participantCaption(_ caption: ParticipantCaption) -> some View {
        switch caption {
        case .own(let text):
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        case .status(let status):
            HStack(spacing: 4) {
                Image(systemName: status == .settled ? "checkmark" : "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(status == .settled ? "Rimborsato" : "In attesa")
                    .font(Typography.caption)
            }
            .foregroundStyle(color(for: status == .settled ? .income : .warning))
        }
    }

    /// A participant's initials disc. Neutral ink-on-fill — an avatar is
    /// identity, not a control (`docs/design/tokens.md`'s "Accent dosage").
    private func avatar(for name: String) -> some View {
        Text(initials(for: name))
            .font(Typography.caption.weight(.bold))
            .foregroundStyle(Palette.inkSecondary)
            .frame(width: 36, height: 36)
            .background(Palette.neutralFill)
            .clipShape(Circle())
    }

    private func initials(for name: String) -> String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    // MARK: Reimbursements

    private var reimbursementsCard: some View {
        Card {
            EyebrowLabel(text: "Rimborsi")
            if advance.status != .open {
                Badge(text: statusLabel, style: .neutral)
            }
            summaryRow(label: "Ricevuto", amount: advance.reimbursed, tint: .income)
            summaryRow(
                label: "Da ricevere", amount: advance.outstanding,
                tint: advance.outstanding > 0 ? .warning : .neutral
            )
            progressBar
            if advance.excess > 0 {
                summaryRow(label: "Rimborsato in eccesso", amount: advance.excess, tint: .warning)
            }
            Divider().overlay(Palette.separator)
            summaryRow(label: "Totale anticipato", amount: advance.receivable, tint: .neutral)
            reimbursementsList
        }
        .confirmationDialog(
            "Eliminare il rimborso?",
            isPresented: Binding(
                get: { reimbursementPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { reimbursementPendingDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: reimbursementPendingDeletion
        ) { reimbursement in
            Button("Elimina", role: .destructive) { onDeleteReimbursement(reimbursement) }
            Button("Chiudi", role: .cancel) {}
        } message: { reimbursement in
            Text(reimbursement.transactionID != nil
                ? "L'importo tornerà tra quelli ancora da ricevere. Il movimento collegato tornerà personale."
                : "L'importo tornerà tra quelli ancora da ricevere.")
        }
    }

    /// The individual reimbursement rows, below the summary figures above —
    /// oldest first, matching `GET /advances/{id}/reimbursements`'s order.
    /// Quiet on `.loading`/an empty list/`.failed`: the totals above already
    /// hold, this is purely the detail underneath them.
    @ViewBuilder
    private var reimbursementsList: some View {
        switch reimbursements {
        case .loading:
            EmptyView()
        case .loaded(let rows):
            if !rows.isEmpty {
                Divider().overlay(Palette.separator)
                ForEach(rows) { reimbursement in
                    reimbursementRow(reimbursement)
                }
            }
        case .failed:
            Text("Non è stato possibile caricare l'elenco dei rimborsi.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
    }

    private func reimbursementRow(_ reimbursement: ReimbursementResponse) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    TraccioCore.formatMoney(
                        amount: reimbursement.amount, currencyCode: advance.currency,
                        explicitSign: true
                    )
                )
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.income)
                .monospacedDigit()
                Text(reimbursementCaption(reimbursement))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button {
                reimbursementPendingDeletion = reimbursement
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Palette.inkSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        }
        .padding(.vertical, 2)
    }

    /// Date · participant name · "collegato a un movimento" · note, each
    /// piece included only when present — same "join what exists" pattern as
    /// `TransactionDetailView.headerSubtitle`.
    private func reimbursementCaption(_ reimbursement: ReimbursementResponse) -> String {
        let dateText = TraccioCore.formatCalendarDate(CalendarDate(date: reimbursement.createdAt))
        let participantName = reimbursement.participantID.flatMap { id in
            advance.participants.first { $0.id == id }?.name
        }
        let linked = reimbursement.transactionID != nil ? "collegato a un movimento" : nil
        return [dateText, participantName, linked, reimbursement.note]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var statusLabel: String {
        switch advance.status {
        case .open: ""  // unreachable — guarded above
        case .settled: "Saldato"
        case .writtenOff: "Stralciato"
        }
    }

    /// "Segna come stralciato" / "Riapri anticipo" and "Aggiungi rimborso" —
    /// `docs/design/canvas/TransactionDetail.dc.html`'s bottom action row.
    /// Reimbursing a written-off advance is refused server-side (`422
    /// advance_written_off`), so "Aggiungi rimborso" hides rather than
    /// surfacing that as a failure banner.
    private var reimbursementActionsRow: some View {
        HStack(spacing: 16) {
            Button {
                if advance.status == .writtenOff {
                    onReopen()
                } else {
                    isConfirmingWriteOff = true
                }
            } label: {
                Text(advance.status == .writtenOff ? "Riapri anticipo" : "Segna come stralciato")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .confirmationDialog(
                "Stralciare l'anticipo?", isPresented: $isConfirmingWriteOff, titleVisibility: .visible
            ) {
                Button("Segna come stralciato", role: .destructive, action: onWriteOff)
                Button("Chiudi", role: .cancel) {}
            } message: {
                Text("L'importo ancora da ricevere non verrà più conteggiato come tale.")
            }

            Spacer()

            if advance.status != .writtenOff {
                PillButton(title: "Aggiungi rimborso", isLoading: isUpdating, action: onAddReimbursement)
            }
        }
    }

    /// Which `Palette` color a `summaryRow` figure carries.
    private enum SummaryTint {
        case income
        case warning
        case neutral
    }

    private func summaryRow(label: String, amount: Int, tint: SummaryTint) -> some View {
        HStack {
            Text(label)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
            Spacer()
            Text(
                TraccioCore.formatMoney(
                    amount: amount, currencyCode: advance.currency, explicitSign: tint == .income
                )
            )
            .font(Typography.body.weight(.bold))
            .foregroundStyle(color(for: tint))
            .monospacedDigit()
        }
    }

    private func color(for tint: SummaryTint) -> Color {
        switch tint {
        case .income: Palette.income
        case .warning: Palette.warning
        case .neutral: Palette.ink
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Palette.neutralFill)
                RoundedRectangle(cornerRadius: 5).fill(Palette.income)
                    .frame(width: geometry.size.width * progressFraction)
            }
        }
        .frame(height: 8)
    }

    private var progressFraction: CGFloat {
        guard advance.receivable > 0 else { return 0 }
        return min(1, CGFloat(advance.reimbursed) / CGFloat(advance.receivable))
    }

    // MARK: Unlink

    /// "Annulla anticipo" — destructive, so it asks first
    /// (`.confirmationDialog`) rather than acting on a single tap. The
    /// inverse of creating one: the transaction reverts to `personal` and its
    /// `effectiveAmount` becomes the full amount again.
    private var unlinkRow: some View {
        Button {
            isConfirmingUnlink = true
        } label: {
            HStack(spacing: 6) {
                if isUpdating {
                    ProgressView().controlSize(.mini)
                }
                Text("Annulla anticipo")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .confirmationDialog(
            "Annullare l'anticipo?", isPresented: $isConfirmingUnlink, titleVisibility: .visible
        ) {
            Button("Annulla anticipo", role: .destructive, action: onUnlink)
            Button("Chiudi", role: .cancel) {}
        } message: {
            Text("Il movimento tornerà a essere una spesa personale.")
        }
    }
}
