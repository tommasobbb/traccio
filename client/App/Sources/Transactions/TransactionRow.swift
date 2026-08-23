import SwiftUI
import TraccioCore

/// One transaction row: description, category, a role/pending badge where
/// relevant, and the amount — following
/// `docs/design/canvas/Transactions.dc.html`.
struct TransactionRow: View {
    let transaction: TransactionResponse
    /// Category id → name, from `TransactionsViewModel.categoryNames`.
    let categoryNames: [UUID: String]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.displayDescription ?? transaction.description)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 8)
            amountColumn
        }
        .padding(14)
        .background(isMuted ? Palette.neutralFill : Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isMuted ? Palette.separator : Palette.separatorSubtle,
                    style: isMuted ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1)
                )
        )
    }

    /// A row is muted when it does not read as a plain, settled personal
    /// spend: still pending, or a leg whose `effectiveAmount` is zero
    /// (transfer, reimbursement).
    private var isMuted: Bool {
        transaction.status == .pending || transaction.effectiveAmount == 0
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 5) {
            if transaction.role != .personal {
                Badge(text: roleLabel, style: roleBadgeStyle)
            } else if transaction.status == .pending {
                Badge(text: "In lavorazione", style: .warning)
            } else if let categoryID = transaction.effectiveCategoryID,
                let name = categoryNames[categoryID]
            {
                Text(name)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private var roleLabel: String {
        switch transaction.role {
        case .personal: ""  // unreachable — guarded by `subtitle`'s condition
        case .transfer: "Trasferimento"
        case .advance: "Anticipo"
        case .reimbursement: "Rimborso"
        }
    }

    private var roleBadgeStyle: Badge.Style {
        switch transaction.role {
        case .personal: .neutral  // unreachable — guarded by `subtitle`'s condition
        case .transfer, .reimbursement: .neutral
        case .advance: .accent
        }
    }

    @ViewBuilder
    private var amountColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if transaction.effectiveAmount == 0 {
                AmountText(
                    amount: transaction.amount,
                    currencyCode: transaction.currency,
                    kind: .notCounted,
                    font: Typography.compactFigure
                )
                Text("non conteggiato")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkQuaternary)
            } else {
                AmountText(
                    amount: transaction.amount,
                    currencyCode: transaction.currency,
                    kind: transaction.amount < 0 ? .spending : .income,
                    font: Typography.compactFigure
                )
            }
        }
    }
}
