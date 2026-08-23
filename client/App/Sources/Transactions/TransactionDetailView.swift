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
/// for a transaction whose advance resolved — every other transaction gets
/// the header and category card alone. No mockup covers the category picker
/// (`docs/design/canvas/TransactionDetail.dc.html` only covers the advance
/// case), so this section is built from existing tokens/components
/// (`Card`, `Badge`, `EyebrowLabel`, `PillButton`, `Banner`) rather than a new
/// design pass.
struct TransactionDetailView: View {
    @State private var model: TransactionDetailViewModel
    /// This transaction's advance, if it has one and the lookup resolved.
    /// Fixed at `init` — an advance's split/participants/reimbursements don't
    /// change as a side effect of a category action.
    private let advance: AdvanceResponse?
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
    /// account:
    ///     This transaction's account, for the header.
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onUpdate:
    ///     Called with the refreshed transaction after a successful
    ///     confirm/clear, so the caller can update its own list in place.
    init(
        transaction: TransactionResponse,
        categories: [CategoryResponse],
        advance: AdvanceResponse?,
        account: AccountResponse?,
        client: any APIClientProtocol = APIClient.devDefault,
        onUpdate: @escaping (TransactionResponse) -> Void
    ) {
        _model = State(
            wrappedValue: TransactionDetailViewModel(
                transaction: transaction, categories: categories, client: client, onUpdate: onUpdate
            )
        )
        self.advance = advance
        self.account = account
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.actionFailure != nil {
                    Banner(message: "Non è stato possibile aggiornare la categoria. Riprova.")
                }
                categoryCard
                if let advance {
                    AdvanceSections(transaction: model.transaction, advance: advance)
                }
            }
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle("Dettaglio movimento")
        .task { await model.loadCategoriesIfNeeded() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let categoryName {
                Badge(text: categoryName, style: .neutral)
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
        let isSelected = category.id == model.transaction.effectiveCategoryID
        return Button {
            Task { await model.confirm(categoryID: category.id) }
        } label: {
            HStack {
                Text(category.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                Spacer()
                if isSelected {
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
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
