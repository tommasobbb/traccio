import SwiftUI
import TraccioCore

/// The advance-specific cards on `TransactionDetailView`: the split, the
/// participants, and the reimbursements — rendered only for a transaction
/// whose advance resolved.
///
/// Presentational only, same reasoning as the screen it used to be: every
/// value it needs was already fetched by `TransactionsViewModel` before the
/// row was tapped, so it all arrives via `init` (`client/CLAUDE.md`: the
/// backend owns every derived value; `receivable`/`reimbursed`/`outstanding`/
/// `excess` are `AdvanceResponse` fields, not recomputed here).
///
/// Follows `docs/design/canvas/TransactionDetail.dc.html`, minus two elements
/// the real data can't honestly support today (`tasks/backlog.md`): the
/// event chip (no endpoint resolves "which event is this transaction in")
/// and per-participant reimbursement status (a `Reimbursement` links only to
/// the advance as a whole, never to a specific `Participant`). Also
/// read-only here: no write-off / add-reimbursement actions.
struct AdvanceSections: View {
    let transaction: TransactionResponse
    let advance: AdvanceResponse

    var body: some View {
        splitCard
        participantsCard
        reimbursementsCard
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
}
