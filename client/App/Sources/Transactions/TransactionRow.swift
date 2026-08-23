import SwiftUI
import TraccioCore

/// One transaction row: description, category, a role/pending badge where
/// relevant, and the amount — following
/// `docs/design/canvas/Transactions.dc.html`.
///
/// An advance-role row with a resolved `AdvanceResponse` also gets a "quota"
/// caption and becomes a `NavigationLink` to `AdvanceDetailView`
/// (`docs/design/canvas/TransactionDetail.dc.html`); every other row,
/// including an advance row whose advance failed to load, stays plain.
struct TransactionRow: View {
    let transaction: TransactionResponse
    /// Category id → name, from `TransactionsViewModel.categoryNames`.
    let categoryNames: [UUID: String]
    /// Transaction id → its advance, from
    /// `TransactionsViewModel.advancesByTransactionID`.
    let advancesByTransactionID: [UUID: AdvanceResponse]
    /// Account id → the account, from `TransactionsViewModel.accountsByID`.
    let accountsByID: [UUID: AccountResponse]

    var body: some View {
        if let advance {
            NavigationLink {
                AdvanceDetailView(
                    transaction: transaction,
                    advance: advance,
                    categoryName: categoryName,
                    account: accountsByID[transaction.accountID]
                )
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
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

    /// This row's advance, when it is one and the fetch resolved it.
    private var advance: AdvanceResponse? {
        guard transaction.role == .advance else { return nil }
        return advancesByTransactionID[transaction.id]
    }

    private var categoryName: String? {
        transaction.effectiveCategoryID.flatMap { categoryNames[$0] }
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
                if let advance {
                    Text(
                        "quota \(TraccioCore.formatMoney(amount: advance.ownShare, currencyCode: transaction.currency)) di \(TraccioCore.formatMoney(amount: abs(transaction.amount), currencyCode: transaction.currency))"
                    )
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                }
            } else if transaction.status == .pending {
                Badge(text: "In lavorazione", style: .warning)
            } else if let categoryName {
                Text(categoryName)
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
