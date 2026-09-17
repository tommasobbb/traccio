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
///
/// `TransactionHeaderCard`, `TransactionCategoryCard`, and
/// `TransactionEventCard` each live in their own file next to this one —
/// this view wires them to `TransactionDetailViewModel` and lays them out
/// alongside `AdvanceSections`/`TransferSection` (already separate) and the
/// two small manual-movement/mark-as-advance cards kept inline here.
struct TransactionDetailView: View {
    @State private var model: TransactionDetailViewModel
    @State private var isPresentingCreateAdvanceSheet = false
    @State private var isPresentingAddReimbursementSheet = false
    @State private var isPresentingEventPickerSheet = false
    @State private var isPresentingCreateRuleSheet = false
    @State private var isPresentingEditSheet = false
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss
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
    /// Shared with the event chip's `NavigationLink` so the push zooms from
    /// the chip's own frame instead of sliding in
    /// (`docs/decisions/0030-liquid-glass-chrome.md`).
    @Namespace private var transitionNamespace

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
        onRulesApplied: @escaping () -> Void = {},
        onDelete: @escaping (UUID) -> Void = { _ in }
    ) {
        _model = State(
            wrappedValue: TransactionDetailViewModel(
                transaction: transaction, advance: advance, categories: categories, transfer: transfer,
                client: client, onUpdate: onUpdate, onAdvanceChange: onAdvanceChange,
                onDashboardStale: onDashboardStale, onRulesApplied: onRulesApplied,
                onDelete: onDelete
            )
        )
        self.account = account
        self.events = events
        self.client = client
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                TransactionHeaderCard(
                    transaction: model.transaction, categoryName: categoryName, account: account
                )
                if let bannerMessage {
                    Banner(message: bannerMessage)
                }
                TransactionCategoryCard(
                    categories: model.categories,
                    transaction: model.transaction,
                    isUpdating: model.isUpdating,
                    onSeedDefaults: { Task { await model.seedDefaultCategories() } },
                    onConfirm: { categoryID in Task { await model.confirm(categoryID: categoryID) } },
                    onClear: { Task { await model.clearCategory() } },
                    onCreateRule: { isPresentingCreateRuleSheet = true }
                )
                TransactionEventCard(
                    eventID: model.transaction.eventID,
                    events: events,
                    client: client,
                    transitionNamespace: transitionNamespace,
                    isUpdating: model.isUpdating,
                    onOpenEventPicker: { isPresentingEventPickerSheet = true },
                    onRemoveFromEvent: { Task { await model.removeFromEvent() } }
                )
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
                if isManual {
                    manualActionsCard
                }
            }
            .padding(Spacing.gutter)
        }
        .screenChrome("Dettaglio movimento")
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
                accountsByID: model.reimbursementCandidateAccounts,
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
        .sheet(isPresented: $isPresentingEditSheet) {
            EditManualTransactionSheet(
                transaction: model.transaction,
                isSaving: model.isUpdating,
                failureMessage: model.actionFailure != nil
                    ? "Non è stato possibile salvare il movimento. Riprova." : nil,
                onSave: { amount, currency, valueDate, description in
                    Task {
                        await model.editManualTransaction(
                            amount: amount, currency: currency, valueDate: valueDate,
                            description: description
                        )
                        if model.actionFailure == nil {
                            isPresentingEditSheet = false
                        }
                    }
                },
                onCancel: { isPresentingEditSheet = false }
            )
        }
        .confirmationDialog(
            "Eliminare questo movimento?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) {
                Task {
                    await model.deleteManualTransaction()
                    if model.actionFailure == nil { dismiss() }
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("L'operazione non è reversibile.")
        }
    }

    // MARK: Manual movement actions (ADR 0020)

    /// Whether this row is on a manual account and so can be edited/deleted.
    private var isManual: Bool {
        account?.source == .manual
    }

    private var manualActionsCard: some View {
        Card {
            EyebrowLabel(text: "Movimento manuale")
            Text("Questo movimento è stato inserito a mano e puoi modificarlo o eliminarlo.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            HStack(spacing: 10) {
                PillButton(title: "Modifica", action: { isPresentingEditSheet = true })
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Text("Elimina")
                        .font(Typography.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.warning)
            }
            .disabled(model.isUpdating)
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
        case .transactionInUse:
            "Il movimento è collegato a un trasferimento o a un anticipo. Scollegalo prima di eliminarlo."
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
}
