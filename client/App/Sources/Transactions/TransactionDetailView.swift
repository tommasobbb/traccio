import SwiftUI
import TraccioCore

/// "Dettaglio movimento" — the generic transaction detail screen, reached by
/// tapping any row in `TransactionsView`.
///
/// The client's first write-with-a-body flow: confirming or clearing a
/// category calls `TransactionDetailViewModel`, which re-fetches the row from
/// the backend rather than deriving the new `effectiveCategoryID` here (the
/// backend owns every derived value, `client/CLAUDE.md`) and hands the result
/// up to `onUpdate` so `TransactionsViewModel.replace(_:)` can update the
/// Movimenti row without a full reload.
///
/// The header and advance cards previously lived in a dedicated
/// `AdvanceDetailView`; that view is now `AdvanceSections`, embedded here only
/// for a transaction whose advance resolved (`model.advance`, kept in the
/// view model rather than a fixed `let` — creating or deleting the advance
/// right here changes it, unlike the category-confirmation flow's other
/// side effects). An eligible transaction with no advance
/// (`TraccioCore.canBecomeAdvance(_:)`) instead gets a "Segna come anticipo"
/// card presenting `CreateAdvanceSheet`. A transaction whose `role ==
/// .transfer` and whose transfer resolved additionally gets `TransferSection`
/// — the counterpart leg and an "Annulla collegamento" action. No mockup
/// covers the category picker, the advance-creation flow, or the transfer
/// card (`docs/design/canvas/TransactionDetail.dc.html` only covers the
/// already-created advance case), so all three are built from existing
/// tokens/components (`Card`, `Badge`, `EyebrowLabel`, `PillButton`,
/// `Banner`) rather than a new design pass.
struct TransactionDetailView: View {
    @State private var model: TransactionDetailViewModel
    @State private var isPresentingCreateAdvanceSheet = false
    @State private var isPresentingAddReimbursementSheet = false
    /// The account this transaction belongs to, for the header's currency
    /// line. Best-effort, so `nil` degrades to a generic label rather than
    /// hiding the header.
    private let account: AccountResponse?

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// transaction:
    ///     The transaction to show and act on.
    /// categories:
    ///     Categories already fetched by the caller (`TransactionsViewModel`),
    ///     or empty to have the view model fetch them itself.
    /// advance:
    ///     This transaction's advance, if role is `.advance` and the lookup
    ///     resolved.
    /// transfer:
    ///     This transaction's confirmed transfer, if role is `.transfer` and
    ///     the lookup resolved.
    /// account:
    ///     This transaction's account, for the header.
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onUpdate:
    ///     Called with the refreshed transaction after a successful
    ///     confirm/clear, so the caller can update its own list in place.
    /// onAdvanceChange:
    ///     Called with this transaction's current advance after a successful
    ///     create/delete, so the caller can keep its own advance lookup in
    ///     place. Defaults to a no-op.
    init(
        transaction: TransactionResponse,
        categories: [CategoryResponse],
        advance: AdvanceResponse?,
        transfer: TransferResponse? = nil,
        account: AccountResponse?,
        client: any APIClientProtocol = APIClient.devDefault,
        onUpdate: @escaping (TransactionResponse) -> Void,
        onAdvanceChange: @escaping (AdvanceResponse?) -> Void = { _ in }
    ) {
        _model = State(
            wrappedValue: TransactionDetailViewModel(
                transaction: transaction, advance: advance, categories: categories, transfer: transfer,
                client: client, onUpdate: onUpdate, onAdvanceChange: onAdvanceChange
            )
        )
        self.account = account
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.actionFailure != nil {
                    Banner(message: "Non è stato possibile completare l'operazione. Riprova.")
                }
                categoryCard
                if let advance = model.advance {
                    AdvanceSections(
                        transaction: model.transaction,
                        advance: advance,
                        isUpdating: model.isUpdating,
                        onUnlink: { Task { await model.deleteAdvance() } },
                        onWriteOff: { Task { await model.writeOffAdvance() } },
                        onReopen: { Task { await model.reopenAdvance() } },
                        onAddReimbursement: {
                            Task { await model.loadReimbursementCandidatesIfNeeded() }
                            isPresentingAddReimbursementSheet = true
                        }
                    )
                } else if TraccioCore.canBecomeAdvance(model.transaction) {
                    markAsAdvanceCard
                }
                if model.transfer != nil {
                    TransferSection(
                        counterpart: model.counterpartTransaction,
                        isUnlinking: model.isUpdating,
                        onUnlink: { Task { await model.unlinkTransfer() } }
                    )
                }
            }
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle("Dettaglio movimento")
        .task {
            await model.loadCategoriesIfNeeded()
            await model.loadTransferIfNeeded()
        }
        .sheet(isPresented: $isPresentingCreateAdvanceSheet) {
            CreateAdvanceSheet(
                transaction: model.transaction,
                isCreating: model.isUpdating,
                failureMessage: model.actionFailure != nil
                    ? "Non è stato possibile creare l'anticipo. Riprova." : nil,
                onCreate: { ownShare, participants in
                    Task {
                        await model.createAdvance(ownShare: ownShare, participants: participants)
                        if model.actionFailure == nil {
                            isPresentingCreateAdvanceSheet = false
                        }
                    }
                },
                onCancel: { isPresentingCreateAdvanceSheet = false }
            )
        }
        .sheet(isPresented: $isPresentingAddReimbursementSheet) {
            AddReimbursementSheet(
                candidates: model.reimbursementCandidates,
                isCreating: model.isUpdating,
                failureMessage: model.actionFailure != nil
                    ? "Non è stato possibile registrare il rimborso. Riprova." : nil,
                onCreate: { amount, transactionID, note in
                    Task {
                        await model.createReimbursement(
                            amount: amount, transactionID: transactionID, note: note
                        )
                        if model.actionFailure == nil {
                            isPresentingAddReimbursementSheet = false
                        }
                    }
                },
                onCancel: { isPresentingAddReimbursementSheet = false }
            )
        }
    }

    // MARK: Advance

    private var markAsAdvanceCard: some View {
        Card {
            EyebrowLabel(text: "Anticipo")
            Text("Hai pagato per qualcun altro su questo movimento?")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            PillButton(
                title: "Segna come anticipo",
                action: { isPresentingCreateAdvanceSheet = true }
            )
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let categoryName {
                HStack(spacing: 6) {
                    Badge(text: categoryName, style: .neutral)
                    // A rule-generated suggestion must not render like an
                    // explicit user confirmation, now that `POST
                    // /rules/apply` can produce one.
                    if model.transaction.confirmedCategoryID == nil {
                        Badge(text: "Suggerita", style: .neutral)
                    }
                }
            }
            Text(model.transaction.displayDescription ?? model.transaction.description)
                .font(Typography.statFigure)
                .foregroundStyle(Palette.ink)
            Text(headerSubtitle)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    /// The effective category's display name, resolved against
    /// `model.categories` — recomputed whenever either changes, so a fresh
    /// confirm/clear is reflected immediately.
    private var categoryName: String? {
        guard let id = model.transaction.effectiveCategoryID else { return nil }
        return model.categories.first { $0.id == id }?.name
    }

    private var headerSubtitle: String {
        let dateTime = model.transaction.effectiveDate.map { date -> String in
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy, HH:mm")
            return formatter.string(from: date)
        }
        let accountLabel = "\(account?.name ?? "Conto") \(model.transaction.currency)"
        return [dateTime, accountLabel].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Category

    private var categoryCard: some View {
        Card {
            EyebrowLabel(text: "Categoria")
            if model.categories.isEmpty {
                emptyCategoriesState
            } else {
                categoryList
                if model.transaction.confirmedCategoryID != nil {
                    Divider().overlay(Palette.separator)
                    clearCategoryRow
                }
            }
        }
    }

    /// A fresh database has no categories yet — the picker would dead-end
    /// without a way to seed the defaults (`POST /categories/defaults`).
    private var emptyCategoriesState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Non hai ancora nessuna categoria.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            PillButton(
                title: "Crea categorie predefinite",
                isLoading: model.isUpdating,
                action: { Task { await model.seedDefaultCategories() } }
            )
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(model.categories) { category in
                categoryRow(category)
                if category.id != model.categories.last?.id {
                    Divider().overlay(Palette.separator)
                }
            }
        }
    }

    private func categoryRow(_ category: CategoryResponse) -> some View {
        let isConfirmed = category.id == model.transaction.confirmedCategoryID
        // A suggestion renders as a lightweight tag, never the checkmark
        // reserved for an explicit confirmation — tapping still confirms it,
        // same as any other row.
        let isSuggestedOnly =
            !isConfirmed && category.id == model.transaction.suggestedCategoryID
        return Button {
            Task { await model.confirm(categoryID: category.id) }
        } label: {
            HStack {
                Text(category.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                if isSuggestedOnly {
                    Badge(text: "Suggerita", style: .neutral)
                }
                Spacer()
                if isConfirmed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isUpdating)
        .accessibilityAddTraits(isConfirmed ? [.isSelected] : [])
    }

    private var clearCategoryRow: some View {
        Button {
            Task { await model.clearCategory() }
        } label: {
            Text("Rimuovi categoria")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isUpdating)
    }
}
