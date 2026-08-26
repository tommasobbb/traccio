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
    @State private var isPresentingEventPickerSheet = false
    @State private var isPresentingCreateRuleSheet = false
    /// The account this transaction belongs to, for the header's currency
    /// line. Best-effort, so `nil` degrades to a generic label rather than
    /// hiding the header.
    private let account: AccountResponse?
    /// The caller's events, for resolving `transaction.eventID` to a display
    /// name and, when it resolves, a `NavigationLink` to `EventDetailView`.
    /// Best-effort: an unresolved `eventID` (event not in this list, e.g. a
    /// stale local page) still shows the chip, just as a non-navigable row —
    /// same degradation `AdvanceEligibility`'s row already uses elsewhere.
    private let events: [EventResponse]
    /// The client `EventDetailView` reaches the backend through, so
    /// navigating to it shares this screen's connection rather than
    /// defaulting a second one.
    private let client: any APIClientProtocol

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
    /// events:
    ///     Events already fetched by the caller (`TransactionsViewModel`), to
    ///     resolve `transaction.eventID`'s name and navigation target.
    ///     Defaults to empty, which degrades the chip to non-navigable.
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
    /// onDashboardStale:
    ///     Called after any successful write that can change the dashboard's
    ///     totals, so the caller can invalidate `DataFreshness.Scope.dashboard`.
    ///     Defaults to a no-op.
    /// onRulesApplied:
    ///     Called after "Categorizza sempre così" successfully creates a rule
    ///     and re-applies every rule, so the caller can invalidate
    ///     `DataFreshness.Scope.transactions`/`.dashboard`. Defaults to a
    ///     no-op.
    init(
        transaction: TransactionResponse,
        categories: [CategoryResponse],
        advance: AdvanceResponse?,
        transfer: TransferResponse? = nil,
        account: AccountResponse?,
        events: [EventResponse] = [],
        client: any APIClientProtocol = APIClient.current,
        onUpdate: @escaping (TransactionResponse) -> Void,
        onAdvanceChange: @escaping (AdvanceResponse?) -> Void = { _ in },
        onDashboardStale: @escaping () -> Void = {},
        onRulesApplied: @escaping () -> Void = {}
    ) {
        _model = State(
            wrappedValue: TransactionDetailViewModel(
                transaction: transaction, advance: advance, categories: categories, transfer: transfer,
                client: client, onUpdate: onUpdate, onAdvanceChange: onAdvanceChange,
                onDashboardStale: onDashboardStale, onRulesApplied: onRulesApplied
            )
        )
        self.account = account
        self.events = events
        self.client = client
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let bannerMessage {
                    Banner(message: bannerMessage)
                }
                categoryCard
                eventCard
                if let advance = model.advance {
                    AdvanceSections(
                        transaction: model.transaction,
                        advance: advance,
                        reimbursements: model.reimbursements,
                        isUpdating: model.isUpdating,
                        onUnlink: { Task { await model.deleteAdvance() } },
                        onWriteOff: { Task { await model.writeOffAdvance() } },
                        onReopen: { Task { await model.reopenAdvance() } },
                        onAddReimbursement: {
                            Task { await model.loadReimbursementCandidatesIfNeeded() }
                            isPresentingAddReimbursementSheet = true
                        },
                        onDeleteReimbursement: { reimbursement in
                            Task { await model.deleteReimbursement(reimbursement) }
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
        .sensoryFeedback(.success, trigger: model.successTick)
        .sensoryFeedback(.error, trigger: model.actionFailure)
        .task {
            await model.loadCategoriesIfNeeded()
            await model.loadTransferIfNeeded()
            await model.loadReimbursements()
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
                participants: model.advance?.participants ?? [],
                isCreating: model.isUpdating,
                failureMessage: model.actionFailure != nil
                    ? "Non è stato possibile registrare il rimborso. Riprova." : nil,
                onCreate: { draft in
                    Task {
                        await model.createReimbursement(
                            amount: draft.amount, transactionID: draft.transactionID,
                            participantID: draft.participantID, note: draft.note
                        )
                        if model.actionFailure == nil {
                            isPresentingAddReimbursementSheet = false
                        }
                    }
                },
                onCancel: { isPresentingAddReimbursementSheet = false }
            )
        }
        .sheet(isPresented: $isPresentingCreateRuleSheet) {
            CreateRuleFromTransactionSheet(
                categoryName: categoryName ?? "",
                initialPattern: model.transaction.displayDescription ?? model.transaction.description,
                isCreating: model.isUpdating,
                failureMessage: createRuleFailureMessage,
                onCreate: { matchKind, pattern in
                    guard let categoryID = model.transaction.confirmedCategoryID else { return }
                    Task {
                        await model.createRuleAndApplyRules(
                            categoryID: categoryID, matchKind: matchKind, pattern: pattern
                        )
                        if model.actionFailure == nil {
                            isPresentingCreateRuleSheet = false
                        }
                    }
                },
                onCancel: { isPresentingCreateRuleSheet = false }
            )
        }
        .sheet(isPresented: $isPresentingEventPickerSheet) {
            EventPickerSheet(
                events: events,
                selectedEventID: model.transaction.eventID,
                isUpdating: model.isUpdating,
                failureMessage: bannerMessage,
                onSelect: { eventID in
                    Task {
                        await model.assignToEvent(eventID)
                        if model.actionFailure == nil {
                            isPresentingEventPickerSheet = false
                        }
                    }
                },
                onCancel: { isPresentingEventPickerSheet = false }
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

    /// The top banner's copy for the current `model.actionFailure`, `nil`
    /// when there is none. Most actions on this screen share the generic
    /// fallback; event-membership failures get their own copy since they
    /// name a specific, recoverable cause rather than "something went
    /// wrong."
    private var bannerMessage: String? {
        switch model.actionFailure {
        case nil: nil
        case .transactionInAnotherEvent: "Il movimento è già assegnato a un altro evento."
        case .mixedCurrency: "Questo movimento ha una valuta diversa da quella dell'evento."
        case .duplicateRule: "Esiste già una regola così."
        case .generic: "Non è stato possibile completare l'operazione. Riprova."
        }
    }

    /// `CreateRuleFromTransactionSheet`'s own failure copy — separate from
    /// `bannerMessage` so a duplicate-rule error reads specifically inside
    /// the sheet that caused it, rather than the screen's generic banner.
    private var createRuleFailureMessage: String? {
        guard let failure = model.actionFailure else { return nil }
        return failure == .duplicateRule
            ? "Esiste già una regola così."
            : "Non è stato possibile creare la regola. Riprova."
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
                    PillButton(
                        title: "Categorizza sempre così",
                        action: { isPresentingCreateRuleSheet = true }
                    )
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

    /// Two-level picker (ADR 0018): each root immediately followed by its own
    /// children, indented — `TraccioCore.categoryTree(_:)` does the pure
    /// regrouping, this view only adds indentation.
    private var categoryList: some View {
        let tree = TraccioCore.categoryTree(model.categories)
        return VStack(spacing: 0) {
            ForEach(tree) { node in
                categoryRow(node.category, indented: false)
                if !node.children.isEmpty {
                    Divider().overlay(Palette.separatorSubtle)
                }
                ForEach(node.children) { child in
                    categoryRow(child, indented: true)
                    if child.id != node.children.last?.id {
                        Divider().overlay(Palette.separatorSubtle)
                    }
                }
                if node.id != tree.last?.id {
                    Divider().overlay(Palette.separator)
                }
            }
        }
    }

    private func categoryRow(_ category: CategoryResponse, indented: Bool) -> some View {
        let isConfirmed = category.id == model.transaction.confirmedCategoryID
        // A suggestion renders as a lightweight tag, never the checkmark
        // reserved for an explicit confirmation — tapping still confirms it,
        // same as any other row.
        let isSuggestedOnly =
            !isConfirmed && category.id == model.transaction.suggestedCategoryID
        return Button {
            Task { await model.confirm(categoryID: category.id) }
        } label: {
            HStack(spacing: 10) {
                IconTile(
                    systemImage: (category.icon ?? .other).systemImageName,
                    color: category.color,
                    diameter: 28
                )
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
            .padding(.vertical, 8)
            .padding(.leading, indented ? 24 : 0)
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

    // MARK: Event

    /// The event card: a chip naming this transaction's event, plus the
    /// actions to change it — closes the "assign to event" gap left open
    /// when `event_id` first landed on the read model (see
    /// `tasks/backlog.md`), which only let a transaction be *added* to an
    /// event from the event's own detail screen (`AddEventMembersSheet`).
    /// This card is the reverse direction, so unlike the read-only chip it
    /// replaced, it renders even without an event.
    ///
    /// The chip is a `NavigationLink` to `EventDetailView` when the event
    /// resolved against `events` (the caller's already-fetched list);
    /// otherwise a non-navigable row showing a generic label, the same
    /// degrade `TransactionRow`'s advance lookup already uses — the
    /// backend, not a stale local list, stays the authority on whether the
    /// event still exists.
    private var eventCard: some View {
        Card {
            EyebrowLabel(text: "Evento")
            if let eventID = model.transaction.eventID {
                if let event = events.first(where: { $0.id == eventID }) {
                    NavigationLink {
                        EventDetailView(event: event, client: client)
                    } label: {
                        eventRow(name: event.name, isNavigable: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    eventRow(name: "Evento", isNavigable: false)
                }
                Divider().overlay(Palette.separator)
                eventActionRow(title: "Cambia evento") { isPresentingEventPickerSheet = true }
                eventActionRow(title: "Rimuovi dall'evento") {
                    Task { await model.removeFromEvent() }
                }
            } else {
                eventActionRow(title: "Assegna a un evento") { isPresentingEventPickerSheet = true }
            }
        }
    }

    private func eventActionRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isUpdating)
    }

    private func eventRow(name: String, isNavigable: Bool) -> some View {
        HStack {
            Text(name)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(isNavigable ? Palette.ink : Palette.inkSecondary)
            Spacer()
            if isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
