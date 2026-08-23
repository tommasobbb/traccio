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
/// Follows `docs/design/canvas/TransactionDetail.dc.html`, minus two elements
/// the real data can't honestly support today (`tasks/backlog.md`): the
/// event chip (no endpoint resolves "which event is this transaction in")
/// and per-participant reimbursement status (a `Reimbursement` links only to
/// the advance as a whole, never to a specific `Participant`).
struct AdvanceSections: View {
    let transaction: TransactionResponse
    let advance: AdvanceResponse
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

    @State private var isConfirmingUnlink = false
    @State private var isConfirmingWriteOff = false

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

    private var splitBar: some View {
        HStack(spacing: 3) {
            ForEach(0..<splitCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index == 0 ? Palette.accent : Palette.neutralFill)
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
                caption: "Quota propria — nessun rimborso dovuto"
            )
            ForEach(Array(advance.participants.enumerated()), id: \.offset) { _, participant in
                Divider().overlay(Palette.separator)
                participantRow(name: participant.name, amount: participant.expectedAmount, caption: nil)
            }
        }
    }

    private func participantRow(name: String, amount: Int, caption: String?) -> some View {
        HStack(spacing: 12) {
            avatar(for: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                if let caption {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer()
            Text(TraccioCore.formatMoney(amount: amount, currencyCode: advance.currency))
                .font(Typography.body.weight(.bold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
    }

    private func avatar(for name: String) -> some View {
        Text(initials(for: name))
            .font(Typography.caption.weight(.bold))
            .foregroundStyle(Palette.accent)
            .frame(width: 36, height: 36)
            .background(Palette.accent.opacity(0.12))
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
        }
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
