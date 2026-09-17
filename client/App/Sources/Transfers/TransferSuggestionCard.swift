import SwiftUI
import TraccioCore

/// One suggested transfer pair on `TransfersView`: which accounts, both
/// legs' date and amount, and `Conferma`/`Ignora` actions.
///
/// No mockup covers this (`docs/design/canvas/Transactions.dc.html` only
/// shows the confirmed `Trasferimento` role badge), so it is built from
/// existing tokens/components — `Card`, `EyebrowLabel`, `AmountText`,
/// `PillButton` — the same posture `TransactionDetailView`'s category card
/// took.
struct TransferSuggestionCard: View {
    let pair: TransferSuggestionPair
    /// Account id → account, for the accounts line. Best-effort: a missing
    /// lookup falls back to a generic label rather than hiding the card.
    let accountsByID: [UUID: AccountResponse]
    let isUpdating: Bool
    let onConfirm: () -> Void
    let onReject: () -> Void

    private var isFundedPayment: Bool { pair.suggestion.kind == .fundedPayment }

    var body: some View {
        Card {
            EyebrowLabel(text: isFundedPayment ? "Doppia uscita" : "Possibile trasferimento")
            Text(accountsLine)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
            if isFundedPayment {
                Text("Questa uscita ne finanzia un'altra: verrà contata una volta sola.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            legRow(pair.outgoing)
            legRow(pair.incoming)
            if pair.suggestion.amountDelta != 0 {
                Text(
                    "Differenza di \(TraccioCore.formatMoney(amount: pair.suggestion.amountDelta, currencyCode: pair.suggestion.currency))"
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            }
            actions
        }
    }

    private var accountsLine: String {
        let outgoingName = accountsByID[pair.outgoing.accountID]?.name ?? "Conto"
        let incomingName = accountsByID[pair.incoming.accountID]?.name ?? "Conto"
        // Funded payment: the funding account pays for the purchase on the
        // other. Two-sided: money moves from one to the other.
        return "\(outgoingName) → \(incomingName)"
    }

    private func legRow(_ leg: TransactionResponse) -> some View {
        HStack {
            if let date = leg.effectiveDate {
                Text(Self.dateFormatter.string(from: date))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            AmountText(
                amount: leg.amount, currencyCode: leg.currency,
                kind: leg.amount < 0 ? .spending : .income, font: Typography.compactFigure
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            PillButton(title: "Conferma", isLoading: isUpdating, action: onConfirm)
            Button(action: onReject) {
                Text("Ignora")
                    .font(Typography.eyebrow)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Palette.neutralFill)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        }
    }

    /// One `DateFormatter` shared by every `TransferSuggestionCard`, not one
    /// per value — a `static let` is a single instance for the whole type,
    /// same as at package scope. Safe here only because SwiftUI infers
    /// `@MainActor` for every `View` conformance, so this non-`Sendable`
    /// formatter is never actually touched from more than one isolation
    /// domain; it is not safe by virtue of being `private` or `static` on a
    /// value type, and does not generalize to a non-`View` type.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter
    }()
}
