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
    /// Category id → the full category, from
    /// `TransactionsViewModel.categoriesByID` — the leading `IconTile` needs
    /// the colour/icon, not just the name `categoryNames` carries.
    let categoriesByID: [UUID: CategoryResponse]
    /// Transaction id → its advance, from
    /// `TransactionsViewModel.advancesByTransactionID`.
    let advancesByTransactionID: [UUID: AdvanceResponse]
    /// Transaction id → its confirmed transfer (either leg), from
    /// `TransactionsViewModel.transfersByTransactionID`.
    let transfersByTransactionID: [UUID: TransferResponse]
    /// Account id → the account, from `TransactionsViewModel.accountsByID`.
    let accountsByID: [UUID: AccountResponse]
    /// The caller's events, from `TransactionsViewModel.events`, threaded to
    /// `TransactionDetailView`'s event chip.
    let events: [EventResponse]
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
    /// Called after any successful write on the detail screen that can
    /// change the dashboard's totals, so the caller can invalidate
    /// `DataFreshness.Scope.dashboard`.
    let onDashboardStale: () -> Void
    /// Called after "Categorizza sempre così" successfully creates a rule
    /// and re-applies every rule, so the caller can invalidate
    /// `DataFreshness.Scope.transactions`/`.dashboard`.
    let onRulesApplied: () -> Void
    /// Called with this transaction's id after it is deleted from the detail
    /// screen (a manual movement, ADR 0020), so
    /// `TransactionsViewModel.remove(id:)` can drop the row.
    let onDelete: (UUID) -> Void
    /// When non-`nil`, the row is in transfer-pairing selection mode: it
    /// renders a leading checkbox and toggles selection on tap instead of
    /// navigating to the detail screen (`docs/domain.md` §Transfer).
    var selection: Selection? = nil

    /// The row's state while the Movimenti list is in transfer-pairing
    /// selection mode.
    struct Selection {
        let isSelected: Bool
        /// `false` renders the checkbox greyed and blocks the tap — the row
        /// cannot join the current selection (wrong sign, same account,
        /// different currency, not `personal`, or two are already picked).
        let isSelectable: Bool
        let onToggle: () -> Void
    }

    var body: some View {
        if let selection {
            Button(action: selection.onToggle) {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(!selection.isSelectable && !selection.isSelected)
        } else {
            NavigationLink {
                TransactionDetailView(
                    transaction: transaction,
                    categories: categories,
                    advance: advance,
                    transfer: transfersByTransactionID[transaction.id],
                    account: accountsByID[transaction.accountID],
                    events: events,
                    client: client,
                    onUpdate: onUpdate,
                    onAdvanceChange: onAdvanceUpdate,
                    onDashboardStale: onDashboardStale,
                    onRulesApplied: onRulesApplied,
                    onDelete: onDelete
                )
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            leadingTile
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
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(
                    isMuted ? Palette.separator : Palette.separatorSubtle,
                    style: isMuted ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1)
                )
        )
    }

    /// The 28pt leading element: normally the category `IconTile`, but a
    /// selection checkbox *in its place* while transfer-pairing mode is
    /// active. Same footprint either way, so entering selection mode does not
    /// change the row's layout or steal width from the description
    /// (`docs/design/tokens.md`: never wrap) — unlike the old checkbox, which
    /// sat outside the card and shifted everything.
    @ViewBuilder
    private var leadingTile: some View {
        if let selection {
            Image(systemName: selection.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(
                    selection.isSelected
                        ? Palette.accent
                        : (selection.isSelectable ? Palette.inkTertiary : Palette.inkQuaternary)
                )
                .frame(width: 28, height: 28)
        } else {
            IconTile(systemImage: categoryTileIcon, color: categoryTileColor, diameter: 28)
        }
    }

    /// This row's advance, when it is one and the fetch resolved it.
    private var advance: AdvanceResponse? {
        guard transaction.role == .advance else { return nil }
        return advancesByTransactionID[transaction.id]
    }

    /// The account this row belongs to, when the fetch resolved it — the
    /// source for both the subtitle's account dot and its name.
    private var account: AccountResponse? {
        accountsByID[transaction.accountID]
    }

    private var categoryName: String? {
        transaction.effectiveCategoryID.flatMap { categoryNames[$0] }
    }

    /// The full effective category, for the leading `IconTile` — falls back
    /// to `nil` (rendered as the shared "uncategorized" tile) rather than a
    /// placeholder category, since `nil` is a real, distinct state.
    private var effectiveCategory: CategoryResponse? {
        transaction.effectiveCategoryID.flatMap { categoriesByID[$0] }
    }

    private var categoryTileIcon: String {
        (effectiveCategory?.tileIcon ?? .other).systemImageName
    }

    private var categoryTileColor: PaletteColor {
        effectiveCategory?.color ?? .slate
    }

    /// A row is muted when it does not read as a plain, settled personal
    /// spend: still pending, or a leg whose `effectiveAmount` is zero
    /// (transfer, reimbursement).
    private var isMuted: Bool {
        transaction.status == .pending || transaction.effectiveAmount == 0
    }

    /// The subtitle is one truncating line, not the old mutually-exclusive
    /// branches — a role/pending badge, the account (a 6pt dot, deliberately
    /// too small to compete with the category tile's colour claim — the
    /// account/category colour hierarchy described in the milestone plan),
    /// and the category or advance caption can now all appear together.
    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 5) {
            if let leadingBadge {
                Badge(text: leadingBadge.text, style: leadingBadge.style)
            }
            if let account {
                Circle()
                    .fill(Palette.color(account.tileColor))
                    .frame(width: 6, height: 6)
            }
            if !captionText.isEmpty {
                Text(captionText)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// The one badge this row shows, if any — role takes precedence over the
    /// pending marker (a pending transfer/advance still reads as that role
    /// first), and a plain personal, settled row shows neither.
    private var leadingBadge: (text: String, style: Badge.Style)? {
        if transaction.role != .personal {
            return (roleLabel, roleBadgeStyle)
        }
        if transaction.status == .pending {
            return ("In lavorazione", .warning)
        }
        return nil
    }

    /// The account name, then either the advance quota or the category name
    /// — joined into the single trailing caption `subtitle` renders after the
    /// badge and the account dot.
    private var captionPieces: [String] {
        var pieces: [String] = []
        if let account {
            pieces.append(account.displayName ?? "Conto")
        }
        if let advance {
            pieces.append(
                "quota \(TraccioCore.formatMoney(amount: advance.ownShare, currencyCode: transaction.currency)) di \(TraccioCore.formatMoney(amount: abs(transaction.amount), currencyCode: transaction.currency))"
            )
        } else if let categoryName {
            // A rule-generated suggestion must not read like a confirmed
            // category — appended rather than styled differently, to avoid a
            // second color claim for one caption.
            pieces.append(
                transaction.confirmedCategoryID == nil ? "\(categoryName) · suggerita" : categoryName
            )
        }
        return pieces
    }

    private var captionText: String {
        captionPieces.joined(separator: " · ")
    }

    private var roleLabel: String {
        switch transaction.role {
        case .personal: ""  // unreachable — guarded by `subtitle`'s condition
        case .transfer: "Trasferimento"
        case .funding: "Ricarica"
        case .advance: "Anticipo"
        case .reimbursement: "Rimborso"
        }
    }

    private var roleBadgeStyle: Badge.Style {
        switch transaction.role {
        case .personal: .neutral  // unreachable — guarded by `subtitle`'s condition
        case .transfer, .funding, .reimbursement: .neutral
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
                    .font(Typography.eyebrow)
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
