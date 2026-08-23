import SwiftUI
import TraccioCore

/// One transaction row: description, category, a role/pending badge where
/// relevant, and the amount — following
/// `docs/design/canvas/Transactions.dc.html`.
///
/// Every row is a `NavigationLink` to `TransactionDetailView`
/// (`docs/design/canvas/TransactionDetail.dc.html`) — where a category can be
/// confirmed or cleared, and an advance-role row also gets its "quota"
/// caption and the split/participants/reimbursements cards once the advance
/// lookup resolves.
struct TransactionRow: View {
    let transaction: TransactionResponse
    /// The caller's categories, threaded to `TransactionDetailView`'s picker.
    let categories: [CategoryResponse]
    /// Category id → name, from `TransactionsViewModel.categoryNames`.
    let categoryNames: [UUID: String]
    /// Transaction id → its advance, from
    /// `TransactionsViewModel.advancesByTransactionID`.
    let advancesByTransactionID: [UUID: AdvanceResponse]
    /// Transaction id → its confirmed transfer (either leg), from
    /// `TransactionsViewModel.transfersByTransactionID`.
    let transfersByTransactionID: [UUID: TransferResponse]
    /// Account id → the account, from `TransactionsViewModel.accountsByID`.
    let accountsByID: [UUID: AccountResponse]
    /// The client `TransactionDetailView` reaches the backend through — the
    /// same one `TransactionsViewModel` uses, not a second default instance.
    let client: any APIClientProtocol
    /// Called with the refreshed transaction after a successful category
    /// action, so `TransactionsViewModel.replace(_:)` can update this row's
    /// data without a full reload.
    let onUpdate: (TransactionResponse) -> Void
    /// Called with this transaction's current advance after a successful
    /// create/delete, so `TransactionsViewModel.updateAdvance(_:for:)` can
    /// keep `advancesByTransactionID` in sync — an advance is not part of
    /// `TransactionResponse`, so `onUpdate` alone cannot carry this.
    let onAdvanceUpdate: (AdvanceResponse?) -> Void

    var body: some View {
        NavigationLink {
            TransactionDetailView(
                transaction: transaction,
                categories: categories,
                advance: advance,
                transfer: transfersByTransactionID[transaction.id],
                account: accountsByID[transaction.accountID],
                client: client,
                onUpdate: onUpdate,
                onAdvanceChange: onAdvanceUpdate
            )
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
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
