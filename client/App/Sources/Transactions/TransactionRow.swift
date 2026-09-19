import SwiftUI
import TraccioCore

/// One transaction row: description, category, a role/pending badge where
/// relevant, and the amount — following
/// `docs/design/canvas/Transactions.dc.html`.
///
/// The row is a `NavigationLink` to `TransactionDetailView`
/// (`docs/design/canvas/TransactionDetail.dc.html`) — an advance-role row
/// gets its "quota" caption here and the split/participants/reimbursements
/// cards there once the advance lookup resolves. The leading tile is a
/// second, narrower tap target laid over the link
/// (`docs/decisions/0036-movimenti-row-actions.md`): tapping it opens
/// `CategoryPickerSheet` directly, the two-tap categorization path — tapping
/// anywhere else on the row still pushes to the detail screen.
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
    /// Called with this transaction's id after it is deleted from the detail
    /// screen (a manual movement, ADR 0020), so
    /// `TransactionsViewModel.remove(id:)` can drop the row.
    let onDelete: (UUID) -> Void
    /// Called when the leading tile is tapped, to open `CategoryPickerSheet`
    /// for this row (`docs/decisions/0036-movimenti-row-actions.md`) — the
    /// two-tap categorization path. Absent in selection mode, where the tile
    /// is already a checkbox.
    let onCategorize: (TransactionResponse) -> Void
    /// When non-`nil`, the row is in transfer-pairing selection mode: it
    /// renders a leading checkbox and toggles selection on tap instead of
    /// navigating to the detail screen (`docs/domain.md` §Transfer).
    var selection: Selection? = nil
    /// Shared with `TransactionsView` so the push to `TransactionDetailView`
    /// zooms from this row's own frame instead of sliding in
    /// (`docs/decisions/0030-liquid-glass-chrome.md`).
    let namespace: Namespace.ID

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
        Group {
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
                        onDelete: onDelete
                    )
                    #if os(iOS)
                    .navigationTransition(.zoom(sourceID: transaction.id, in: namespace))
                    #endif
                } label: {
                    rowContent
                }
                .buttonStyle(.pressableRow)
                .matchedTransitionSource(id: transaction.id, in: namespace)
                .overlay(alignment: .leading) { categorizeTapTarget }
            }
        }
        .rowScrollTransition()
    }

    /// An invisible 44×44 tap target centered on the 28pt leading tile,
    /// sitting *beside* the `NavigationLink` rather than nested inside its
    /// label — a `Button` inside a `NavigationLink`'s label would have its
    /// tap swallowed by the link. Only present outside selection mode, where
    /// `leadingTile` is a real category tile rather than a checkbox.
    /// `docs/decisions/0036-movimenti-row-actions.md`'s two-tap
    /// categorization path: this tap opens `CategoryPickerSheet`, the rest of
    /// the row still pushes to `TransactionDetailView`.
    private var categorizeTapTarget: some View {
        Button(action: { onCategorize(transaction) }) {
            Color.clear
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        // Row padding is 16pt, the tile is 28pt: its center sits at 16 + 14 =
        // 30pt from the row's leading edge, so an 8pt inset centers this 44pt
        // target on it.
        .padding(.leading, 8)
        .accessibilityLabel(categorizeAccessibilityLabel)
    }

    private var categorizeAccessibilityLabel: String {
        categoryName.map { "Categoria: \($0)" } ?? "Categorizza"
    }

    /// The row is a plain padded line — no card of its own. Its day group
    /// (`TransactionsView.dayGroup`) is the one container, one elevation, with
    /// hairline dividers between rows (ADR 0008's 2026-09-08 tone revision:
    /// rows floating apart, each with its own shadow, was the vibe-coded
    /// tell). A muted row (pending, or a zero-`effectiveAmount` leg) gets a
    /// faint inset fill instead of the old dashed border.
    private var rowContent: some View {
        HStack(spacing: Spacing.itemGap) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isMuted ? Palette.neutralFill.opacity(0.6) : Palette.card)
        .contentShape(Rectangle())
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
        } else if let effectiveCategory {
            IconTile(systemImage: effectiveCategory.tileIcon.systemImageName, color: effectiveCategory.color, diameter: 28)
        } else {
            uncategorizedTile
        }
    }

    /// A dashed, glyph-only tile marking "not yet categorized" — distinct
    /// from a real category's solid `IconTile` fill, so an uncategorized row
    /// reads as tappable rather than looking like it already has a generic
    /// bucket assigned. No accent colour: this is a data state, not
    /// something currently selected (`docs/design/tokens.md`'s "Accent
    /// dosage").
    private var uncategorizedTile: some View {
        Image(systemName: "tag")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.inkTertiary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(Palette.inkQuaternary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            )
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

    /// A row is muted when it does not read as a plain, settled personal
    /// spend: still pending, or a leg whose `effectiveAmount` is zero
    /// (transfer, reimbursement).
    private var isMuted: Bool {
        transaction.status == .pending || transaction.effectiveAmount == 0
    }

    /// The subtitle is one truncating line: a coloured glyph for the row's
    /// role (a word here was the main cause of the list wrapping —
    /// `docs/design/tokens.md`, "never wrap"), or a small dot for a pending
    /// personal row; then the account as an 8pt colour swatch (deliberately
    /// smaller than the category tile so category still leads the colour
    /// hierarchy — the milestone plan); then the account name plus the
    /// category or advance caption.
    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 5) {
            if transaction.role != .personal {
                roleGlyph
            } else if transaction.status == .pending {
                Circle()
                    .fill(Palette.statusWarn)
                    .frame(width: 6, height: 6)
            }
            if let account {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.color(account.tileColor))
                    .frame(width: 8, height: 8)
            }
            if !captionText.isEmpty {
                Text(captionText)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// A 16pt tile standing in for the role word. Always the neutral
    /// ink-on-fill treatment: a role is metadata, not something you tap, so it
    /// does not take the accent (`docs/design/tokens.md`'s "Accent dosage").
    /// The icon alone distinguishes the roles.
    private var roleGlyph: some View {
        Image(systemName: roleGlyphIcon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Palette.inkSecondary)
            .frame(width: 16, height: 16)
            .background(
                Palette.neutralFill,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .accessibilityLabel(roleLabel)
    }

    /// SF Symbol per role. `.personal` is unreachable — `subtitle` only
    /// renders the glyph when the role is not personal.
    private var roleGlyphIcon: String {
        switch transaction.role {
        case .personal: "circle"
        case .transfer: "arrow.left.arrow.right"
        case .funding: "arrow.down"
        case .advance: "square.stack.3d.up.fill"
        case .reimbursement: "arrow.uturn.backward"
        }
    }

    /// The account name, then either the advance quota or the category name
    /// — joined into the single trailing caption `subtitle` renders after the
    /// glyph and the account swatch. "In lavorazione" leads it for a pending
    /// personal row (a pending role row shows its role glyph instead).
    private var captionPieces: [String] {
        var pieces: [String] = []
        if transaction.role == .personal, transaction.status == .pending {
            pieces.append("In lavorazione")
        }
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

    /// Role name — now only the glyph's accessibility label (the visible
    /// word is gone).
    private var roleLabel: String {
        switch transaction.role {
        case .personal: ""  // unreachable — guarded by `subtitle`'s condition
        case .transfer: "Trasferimento"
        case .funding: "Ricarica"
        case .advance: "Anticipo"
        case .reimbursement: "Rimborso"
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
