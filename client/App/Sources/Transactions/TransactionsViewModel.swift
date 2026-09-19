import Foundation
import Observation
import TraccioCore

/// Drives `TransactionsView`: loads a page of transactions plus the
/// category/advance/account data needed to label and link them, and pages in
/// more as the user scrolls.
///
/// All it does is call `APIClient` and hold the result — no derivation, no
/// arithmetic (that lives in the backend, per `docs/engineering.md`). Nothing
/// here logs or prints a transaction: rows carry amounts, raw bank
/// descriptions, and counterparty names, all sensitive
/// (`docs/engineering.md`).
@MainActor
@Observable
final class TransactionsViewModel {
    /// Why creating a manual movement failed, for the "＋" sheet to surface.
    /// Carries only a status-derived reason, never the response body.
    enum CreateFailure: Equatable {
        /// A `409 account_not_manual` — the chosen account is synced. The
        /// picker only offers manual accounts, so this is effectively
        /// unreachable, but mapped rather than collapsed to `.generic` for
        /// honesty.
        case accountNotManual
        case generic
    }

    /// Why linking two selected rows as a transfer failed, for the selection
    /// bar to surface. Carries only a status-derived reason, never the
    /// response body.
    enum LinkFailure: Equatable {
        /// `409` — one of the two rows is already a leg of another transfer.
        case alreadyLinked
        /// `422` — the pair is not structurally valid (should be unreachable,
        /// since `canLinkSelection` gates the button, but mapped for honesty).
        case notLinkable
        case generic
    }

    /// Why a row action failed, for whichever sheet `TransactionsView.rowAction`
    /// is currently showing to surface. Carries only a status-derived reason,
    /// never the response body — same shape as
    /// `TransactionDetailViewModel.ActionFailure`, which this replaces for
    /// category/advance/manual-movement actions now that they're row-level
    /// (`docs/decisions/0036-movimenti-row-actions.md`).
    enum RowActionFailure: Equatable {
        case generic
        /// `409` from `POST /rules` — a rule with this exact
        /// `(matchKind, pattern)` already exists.
        case duplicateRule
        /// `409 transaction_in_use` from `DELETE /transactions/{id}` — the
        /// manual movement is a leg of a transfer, advance, or reimbursement
        /// and must be unlinked first (ADR 0020).
        case transactionInUse
    }

    /// Current load state, observed by the view.
    private(set) var state: LoadState<[TransactionResponse]> = .idle
    /// The caller's categories, for `TransactionDetailView`'s picker — seeded
    /// there to avoid a flash of empty. Best-effort, same reasoning as
    /// `categoryNames` below.
    private(set) var categories: [CategoryResponse] = []
    /// Category id → name, used to label a row's `effectiveCategoryID`.
    /// Best-effort: a failure to fetch categories leaves this empty rather
    /// than failing the whole screen, since the transaction list is the
    /// primary content.
    private(set) var categoryNames: [UUID: String] = [:]
    /// Category id → the full category, for `TransactionRow`'s leading
    /// `IconTile` (needs the colour/icon, not just the name). Best-effort,
    /// same reasoning as `categoryNames`.
    private(set) var categoriesByID: [UUID: CategoryResponse] = [:]
    /// Transaction id → its advance, for an advance-role row's "quota"
    /// caption and the advance cards on `TransactionDetailView`. Best-effort,
    /// same reasoning as `categoryNames`.
    private(set) var advancesByTransactionID: [UUID: AdvanceResponse] = [:]
    /// Account id → the account, for `TransactionDetailView`'s header line.
    /// Best-effort, same reasoning as `categoryNames`.
    private(set) var accountsByID: [UUID: AccountResponse] = [:]
    /// How many transfer pairs are waiting to be confirmed or rejected, for
    /// the toolbar badge that links to `TransfersView`. Best-effort: a
    /// failure to fetch leaves this at zero, which hides the badge rather
    /// than failing the whole screen.
    private(set) var transferSuggestionCount = 0
    /// Transaction id → its confirmed transfer (keyed by *both* legs), for
    /// `TransactionDetailView`'s "Trasferimento" card, via `TransactionRow`.
    /// Best-effort, same reasoning as `categoryNames`.
    private(set) var transfersByTransactionID: [UUID: TransferResponse] = [:]
    /// The caller's events, for `TransactionDetailView`'s event chip — a
    /// transaction's `eventID` resolves against this to both a display name
    /// and (unlike a category) a full `EventResponse` to navigate to.
    /// Best-effort, same reasoning as `categories`.
    private(set) var events: [EventResponse] = []
    /// The account/category filter currently applied to the list. Always
    /// enforced server-side (see `TransactionFilter`) — the client never
    /// filters an already-fetched page. Set via `applyFilter(_:)`, never
    /// directly, so a change always resets pagination.
    private(set) var filter: TransactionFilter = .none
    /// Set while a manual-movement create is in flight, so the "＋" sheet can
    /// disable its controls.
    private(set) var isCreating = false
    /// Why the most recent manual-movement create failed, if it did.
    private(set) var createFailure: CreateFailure?
    /// Increments once per successful manual create/delete or free-form
    /// transfer link — a trigger for `.sensoryFeedback(.success, trigger:)`,
    /// not a count anyone reads.
    private(set) var successTick = 0
    /// Whether the "pick two rows to link as a transfer" selection mode is
    /// active (ADR: `docs/domain.md` §Transfer — a user may link any
    /// structurally valid pair). Entered from the Movimenti toolbar.
    private(set) var isSelecting = false
    /// The rows currently selected for linking, in tap order, capped at two.
    /// Order is only for stable UI; which leg is outgoing is decided by sign.
    private(set) var selectedIDs: [UUID] = []
    /// Set while a free-form link is in flight, so the selection bar can
    /// disable its button.
    private(set) var isLinking = false
    /// Why the most recent free-form link failed, if it did.
    private(set) var linkFailure: LinkFailure?
    /// Set while a row action (category confirm/clear/seed/create-rule,
    /// mark-as-advance, manual edit/delete) is in flight, so whichever sheet
    /// `TransactionsView.rowAction` is showing can disable its controls.
    /// Shared across every row action rather than one flag each — only one
    /// row-action sheet can be open at a time, so there is never real
    /// overlap to distinguish (same posture as
    /// `TransactionDetailViewModel.isUpdating`, which this replaces for
    /// those actions).
    private(set) var isUpdatingRow = false
    /// Why the most recent row action failed, if it did.
    private(set) var rowActionFailure: RowActionFailure?

    /// Client used to reach the backend. `any APIClientProtocol` rather than
    /// the concrete `APIClient` (`docs/engineering.md`), so a test can
    /// inject a fake. Not `private`: `TransactionsView` reads it to hand the
    /// same client down to `TransactionDetailView`, so both share one
    /// backend connection rather than each defaulting independently.
    let client: any APIClientProtocol
    /// Page size for both the initial load and `loadMore()`.
    private let pageSize: Int
    /// Number of transactions already fetched, i.e. the next page's offset.
    private var offset = 0
    /// Set once a page comes back shorter than `pageSize` — no further page
    /// exists.
    private var reachedEnd = false
    /// Guards `loadMore()` against a second call while one is already
    /// in flight (e.g. two rows crossing the trigger in the same scroll).
    private var isLoadingMore = false
    /// The in-flight debounce for `updateSearchTerm(_:)`, cancelled and
    /// replaced by every call so only the last keystroke within the window
    /// actually reaches the backend.
    private var searchDebounceTask: Task<Void, Never>?
    /// How long `updateSearchTerm(_:)` waits for typing to pause before
    /// applying the filter — long enough to coalesce a fast typist's
    /// keystrokes into one request, short enough that the list still feels
    /// live.
    private static let searchDebounceNanoseconds: UInt64 = 300_000_000

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to fetch through. Defaults to a client pointed at
    ///     the local dev backend.
    /// pageSize:
    ///     Transactions requested per page.
    /// initialFilter:
    ///     The filter to load with, before any user interaction — lets a
    ///     drill-through from another screen (e.g. a future Panoramica
    ///     category/period tap) open Movimenti already filtered.
    init(
        client: any APIClientProtocol = APIClient.current,
        pageSize: Int = 50,
        initialFilter: TransactionFilter = .none
    ) {
        self.client = client
        self.pageSize = pageSize
        self.filter = initialFilter
    }

    /// Fetch the first page of transactions *and* the surrounding context
    /// (categories, accounts, advances, transfers, suggestions, events), and
    /// publish the outcome.
    ///
    /// The two halves are independent: `loadPage()` depends on `filter` and
    /// owns `state`; `loadContext()` does not depend on `filter` and never
    /// fails the screen. `applyFilter(_:)` calls `loadPage()` alone, so
    /// changing a filter is one request — `load()` is for the first appear, a
    /// pull-to-refresh, and a `DataFreshness.transactions` bump, where the
    /// context genuinely may have changed too.
    func load() async {
        async let context: Void = loadContext()
        await loadPage()
        await context
    }

    /// Fetch the first page for the current `filter` and publish it, resetting
    /// pagination. The only part that depends on `filter`, and the only part
    /// that can set `.failed` — an error is surfaced without carrying its
    /// text into the UI (it may reference the response).
    func loadPage() async {
        state = .loading
        offset = 0
        reachedEnd = false
        // A page reload is a context change: drop any in-progress row
        // selection so `selectedIDs` never points at rows no longer shown.
        exitSelection()

        do {
            let page = try await client.transactions(filter: filter, limit: pageSize, offset: 0)
            state = .loaded(page)
            offset = page.count
            reachedEnd = page.count < pageSize
        } catch {
            state = .failed
        }
    }

    /// Fetch everything used to label and link rows — none of it filtered,
    /// all of it best-effort (a failed fetch leaves that map as it was rather
    /// than failing the screen, since the list is the primary content).
    func loadContext() async {
        async let categoriesResult = client.categories()
        async let advancesResult = client.advances(status: nil)
        async let accountsResult = client.accounts()
        async let transferSuggestionsResult = client.transferSuggestions()
        async let transfersResult = client.transfers()
        async let eventsResult = client.events()

        if let fetchedCategories = try? await categoriesResult {
            setCategories(fetchedCategories)
        }
        if let advances = try? await advancesResult {
            advancesByTransactionID = Dictionary(
                uniqueKeysWithValues: advances.advances.map { ($0.transactionID, $0) }
            )
        }
        if let accounts = try? await accountsResult {
            accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        }
        if let suggestions = try? await transferSuggestionsResult {
            transferSuggestionCount = suggestions.count
        }
        if let transfers = try? await transfersResult {
            transfersByTransactionID = Dictionary(
                uniqueKeysWithValues: transfers.flatMap {
                    [($0.outgoingTransactionID, $0), ($0.incomingTransactionID, $0)]
                }
            )
        }
        if let fetchedEvents = try? await eventsResult {
            events = fetchedEvents
        }
    }

    /// Fetch the next page and append it, if there is one.
    ///
    /// A no-op when already loading, already at the end, or the initial load
    /// has not produced a `.loaded` state yet. A failure here leaves the
    /// already-shown transactions in place rather than clearing the screen —
    /// the user can retry by scrolling again.
    func loadMore() async {
        guard case .loaded(let current) = state, !reachedEnd, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await client.transactions(filter: filter, limit: pageSize, offset: offset)
            state = .loaded(current + page)
            offset += page.count
            reachedEnd = page.count < pageSize
        } catch {
            // Keep what's already on screen; the next scroll trigger retries.
        }
    }

    /// Swap one row in place by id, leaving every other row and all
    /// pagination state (`offset`, `reachedEnd`) untouched.
    ///
    /// The refresh path for `TransactionDetailView`'s category actions: after
    /// a confirm/clear, the detail screen re-fetches the single row (its
    /// server-derived `effectiveCategoryID` — see `docs/engineering.md`) and
    /// hands it here, rather than the whole list reloading and losing scroll
    /// position and loaded pages.
    ///
    /// A no-op if `updated.id` is not in the currently loaded list (e.g. the
    /// list reloaded in between) or if the state is not `.loaded`.
    ///
    /// Parameters
    /// ----------
    /// updated:
    ///     The transaction to replace, matched by `id`.
    func replace(_ updated: TransactionResponse) {
        guard case .loaded(let current) = state,
            let index = current.firstIndex(where: { $0.id == updated.id })
        else { return }
        var next = current
        next[index] = updated
        state = .loaded(next)
    }

    /// Remove one row by id, leaving every other row and pagination state
    /// untouched — the counterpart to `replace(_:)` for a manual-movement
    /// delete made from `TransactionDetailView` (ADR 0020).
    ///
    /// A no-op if the id is not in the currently loaded list or the state is
    /// not `.loaded`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to drop.
    func remove(id: UUID) {
        guard case .loaded(let current) = state else { return }
        state = .loaded(current.filter { $0.id != id })
    }

    // MARK: Free-form transfer linking (docs/domain.md §Transfer)

    /// Enter "pick two rows to link as a transfer" mode.
    func enterSelection() {
        isSelecting = true
        selectedIDs = []
        linkFailure = nil
    }

    /// Leave selection mode, discarding any partial selection.
    func exitSelection() {
        isSelecting = false
        selectedIDs = []
        linkFailure = nil
    }

    /// Toggle one row's membership in the selection. Adds only while fewer
    /// than two are selected; removing is always allowed. Clears any prior
    /// `linkFailure` so a fresh attempt starts clean.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction row to toggle.
    func toggleSelection(_ id: UUID) {
        linkFailure = nil
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else if selectedIDs.count < 2 {
            selectedIDs.append(id)
        }
    }

    /// The currently selected rows resolved to their `TransactionResponse`,
    /// in selection order. Rows that dropped out of the loaded page are
    /// simply absent.
    var selectedTransactions: [TransactionResponse] {
        guard case .loaded(let current) = state else { return [] }
        return selectedIDs.compactMap { id in current.first { $0.id == id } }
    }

    /// Whether exactly two rows are selected and form a structurally valid
    /// two-sided transfer pair (`TraccioCore.canLinkAsTransfer`).
    var canLinkAsTwoSided: Bool {
        let selected = selectedTransactions
        guard selected.count == 2 else { return false }
        return TraccioCore.canLinkAsTransfer(selected[0], selected[1])
    }

    /// Whether exactly two rows are selected and form a structurally valid
    /// funded-payment pair (`TraccioCore.canLinkAsFundedPayment`) — two
    /// outflows, one funding the other (ADR 0022). Which leg funds which is
    /// not decided here: sign doesn't disambiguate, so the view asks the
    /// user via a sheet before calling `linkSelectedAsFundedPayment(fundingID:)`.
    var canLinkAsFundedPaymentSelection: Bool {
        let selected = selectedTransactions
        guard selected.count == 2 else { return false }
        return TraccioCore.canLinkAsFundedPayment(selected[0], selected[1])
    }

    /// Whether the current selection can be linked as a transfer of either
    /// kind — gates whether the selection bar shows an action at all.
    var canLinkSelection: Bool {
        canLinkAsTwoSided || canLinkAsFundedPaymentSelection
    }

    /// Link the two selected rows as a two-sided transfer, then update both
    /// rows in place and leave selection mode.
    ///
    /// The outgoing leg is the negative one, the incoming the positive — sign
    /// alone orients a two-sided pair, unlike a funded payment (see
    /// `linkSelectedAsFundedPayment(fundingID:)`).
    ///
    /// Returns
    /// -------
    /// `true` if the transfer was created, `false` otherwise (having recorded
    /// `linkFailure`).
    @discardableResult
    func linkSelectedAsTransfer() async -> Bool {
        guard !isLinking, canLinkAsTwoSided else { return false }
        let selected = selectedTransactions
        let outgoing = selected[0].amount < 0 ? selected[0] : selected[1]
        let incoming = selected[0].amount < 0 ? selected[1] : selected[0]
        return await performLink(outgoing: outgoing, incoming: incoming, kind: .twoSided)
    }

    /// Link the two selected rows as a funded payment, then update both rows
    /// in place and leave selection mode.
    ///
    /// Unlike a two-sided transfer, sign doesn't say which leg funds which —
    /// `fundingID` is the id the user picked (in a disambiguation sheet) as
    /// the leg that pays for the other; it becomes `role=funding` (zeroed),
    /// the other stays `personal` as the real expense.
    ///
    /// Parameters
    /// ----------
    /// fundingID:
    ///     The id of the selected row the user identified as the funding leg.
    ///
    /// Returns
    /// -------
    /// `true` if the transfer was created, `false` otherwise (having recorded
    /// `linkFailure`).
    @discardableResult
    func linkSelectedAsFundedPayment(fundingID: UUID) async -> Bool {
        guard !isLinking, canLinkAsFundedPaymentSelection else { return false }
        let selected = selectedTransactions
        guard let funding = selected.first(where: { $0.id == fundingID }),
            let funded = selected.first(where: { $0.id != fundingID })
        else { return false }
        return await performLink(outgoing: funding, incoming: funded, kind: .fundedPayment)
    }

    /// Shared write behind `linkSelectedAsTransfer()` and
    /// `linkSelectedAsFundedPayment(fundingID:)`: confirm the pair, refresh
    /// both legs (their `role`/`effectiveAmount` changed), and leave
    /// selection mode.
    ///
    /// After `POST /transfers/confirm` succeeds both legs are re-fetched and
    /// swapped in via `replace(_:)`, and the returned transfer is registered
    /// in `transfersByTransactionID` so the detail screen shows "Annulla
    /// collegamento" without a full reload — the same two-leg discipline as
    /// `TransfersViewModel.confirm` / `TransactionDetailViewModel.unlinkTransfer`.
    ///
    /// A `409` surfaces as `.alreadyLinked`, a `422` as `.notLinkable`, any
    /// other failure as `.generic`; the selection is kept so the user can
    /// adjust.
    private func performLink(
        outgoing: TransactionResponse, incoming: TransactionResponse, kind: TransferKind
    ) async -> Bool {
        isLinking = true
        defer { isLinking = false }
        linkFailure = nil

        do {
            let created = try await client.confirmTransfer(
                outgoingID: outgoing.id, incomingID: incoming.id, kind: kind
            )
            async let refreshedOutgoing = client.transaction(id: outgoing.id)
            async let refreshedIncoming = client.transaction(id: incoming.id)
            replace(try await refreshedOutgoing)
            replace(try await refreshedIncoming)
            transfersByTransactionID[created.outgoingTransactionID] = created
            transfersByTransactionID[created.incomingTransactionID] = created
            exitSelection()
            successTick += 1
            return true
        } catch APIError.badStatus(409) {
            linkFailure = .alreadyLinked
            return false
        } catch APIError.badStatus(422) {
            linkFailure = .notLinkable
            return false
        } catch {
            linkFailure = .generic
            return false
        }
    }

    // MARK: Row actions (docs/decisions/0036-movimenti-row-actions.md)

    /// Shared shape for every row-action write in
    /// `TransactionsViewModel+Category.swift`/`+RowActions.swift`: guard
    /// against overlap, run the write, re-fetch the row on success, swap it
    /// in via `replace(_:)` — mirrors `TransactionDetailViewModel.performUpdate`,
    /// relocated here now that these actions start from a row rather than
    /// the pushed detail screen. Not `private`: both extensions call it, and
    /// splitting a class across files means Swift's file-scoped `private`
    /// cannot reach across them (same reasoning as
    /// `TransactionDetailViewModel`'s own doc comment).
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The row to re-fetch and swap in after `write` succeeds.
    /// write:
    ///     The write to perform, given the client and `transactionID`.
    ///
    /// Returns
    /// -------
    /// `true` if the write succeeded, `false` otherwise (having recorded
    /// `rowActionFailure`).
    @discardableResult
    func performRowUpdate(
        for transactionID: UUID,
        _ write: (any APIClientProtocol, UUID) async throws -> Void
    ) async -> Bool {
        guard !isUpdatingRow else { return false }
        isUpdatingRow = true
        defer { isUpdatingRow = false }
        rowActionFailure = nil

        do {
            try await write(client, transactionID)
            let refreshed = try await client.transaction(id: transactionID)
            replace(refreshed)
            successTick += 1
            return true
        } catch {
            rowActionFailure = .generic
            return false
        }
    }

    /// The accounts eligible for a new manual movement — the manual ones
    /// (ADR 0020). A synced account's history is bank-owned; the backend
    /// refuses `POST /transactions` for it, so it never appears in the
    /// picker.
    var manualAccounts: [AccountResponse] {
        accountsByID.values
            .filter { $0.source == .manual }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    /// Create a user-entered movement on a manual account (ADR 0020), then
    /// reload the first page so it lands in day order.
    ///
    /// Reloads the page rather than inserting in place: a back-dated entry
    /// belongs mid-list, and `loadPage()` rebuilds it in the backend's order.
    /// The context (accounts, categories) is unchanged by a create, so it is
    /// not re-fetched. A `409` surfaces as `.accountNotManual`, any other
    /// failure as `.generic`.
    ///
    /// Parameters
    /// ----------
    /// accountID:
    ///     The manual account the movement belongs to.
    /// amount:
    ///     Signed value in minor units — negative out, positive in.
    /// currency:
    ///     ISO 4217 code of `amount`.
    /// valueDate:
    ///     When the movement affects the balance.
    /// description:
    ///     Free text the user typed.
    /// confirmedCategoryID:
    ///     An optional category to confirm at creation.
    ///
    /// Returns
    /// -------
    /// `true` if the movement was created, `false` otherwise (having recorded
    /// `createFailure`).
    @discardableResult
    func createManualTransaction(
        accountID: UUID, amount: Int, currency: String, valueDate: Date,
        description: String, confirmedCategoryID: UUID?
    ) async -> Bool {
        guard !isCreating else { return false }
        isCreating = true
        defer { isCreating = false }
        createFailure = nil

        do {
            _ = try await client.createManualTransaction(
                CreateManualTransactionRequest(
                    accountID: accountID, amount: amount, currency: currency,
                    valueDate: valueDate, description: description,
                    confirmedCategoryID: confirmedCategoryID
                )
            )
            await loadPage()
            successTick += 1
            return true
        } catch APIError.badStatus(409) {
            createFailure = .accountNotManual
            return false
        } catch {
            createFailure = .generic
            return false
        }
    }

    /// Change the active filter and reload the first page — only the page.
    ///
    /// The context (categories, accounts, …) does not depend on the filter,
    /// so a filter change costs exactly one request. `loadPage()` resets
    /// `offset`/`reachedEnd`, since a different filter is a different result
    /// set.
    ///
    /// Parameters
    /// ----------
    /// newFilter:
    ///     The filter to apply from now on, including to `loadMore()`.
    func applyFilter(_ newFilter: TransactionFilter) async {
        filter = newFilter
        await loadPage()
    }

    /// Update the search term, debounced ~300ms so a fast typist fires one
    /// request per pause rather than one per keystroke.
    ///
    /// Cancels any debounce already waiting; only the most recent call
    /// within the window survives to actually change `filter`. Lives here
    /// rather than in the view (`docs/engineering.md`: view models do
    /// orchestration, views stay thin) so it is testable without SwiftUI.
    ///
    /// Parameters
    /// ----------
    /// term:
    ///     The raw text from the search field, not yet trimmed —
    ///     `TransactionFilter.queryItems` already treats a blank term as
    ///     absent.
    func updateSearchTerm(_ term: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            var newFilter = filter
            newFilter.searchTerm = term
            await applyFilter(newFilter)
        }
    }

    /// Begin a row action that doesn't fit `performRowUpdate(for:_:)`'s
    /// write-refetch-replace shape (seeding categories, creating a rule):
    /// guard against overlap. Not `private` for the same file-scoping reason
    /// as `performRowUpdate(for:_:)`.
    ///
    /// Returns
    /// -------
    /// `true`, with `isUpdatingRow` now `true` and any stale
    /// `rowActionFailure` cleared, if no row action was already in flight;
    /// `false` otherwise, in which case the caller should abandon its
    /// attempt without calling `endRowAction(failure:)`.
    func beginRowAction() -> Bool {
        guard !isUpdatingRow else { return false }
        isUpdatingRow = true
        rowActionFailure = nil
        return true
    }

    /// End a row action started with `beginRowAction()`, clearing
    /// `isUpdatingRow` and recording why it failed (`nil` on success).
    func endRowAction(failure: RowActionFailure?) {
        isUpdatingRow = false
        rowActionFailure = failure
    }

    /// Bump the success-tick trigger for
    /// `.sensoryFeedback(.success, trigger:)` — separate from
    /// `endRowAction(failure:)` since not every successful row action
    /// deserves the haptic (e.g. seeding default categories doesn't).
    func markRowActionSucceeded() {
        successTick += 1
    }

    /// Replace the cached category set and its two lookup maps together —
    /// they must never drift apart. Called by `loadContext()` and by
    /// `TransactionsViewModel+Category.seedDefaultCategories()`; not
    /// `private` for the same file-scoping reason as `performRowUpdate(for:_:)`
    /// above.
    ///
    /// Parameters
    /// ----------
    /// categories:
    ///     The caller's full category set, freshly fetched or seeded.
    func setCategories(_ categories: [CategoryResponse]) {
        self.categories = categories
        categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    /// Clear `rowActionFailure`, so a stale error from a previous row action
    /// doesn't reappear in a freshly opened sheet.
    func clearRowActionFailure() {
        rowActionFailure = nil
    }

    /// Set or clear `advancesByTransactionID`'s entry for one transaction.
    ///
    /// The `advancesByTransactionID` counterpart to `replace(_:)`: an
    /// advance is not part of `TransactionResponse`, so creating, deleting,
    /// writing off, reopening, or reimbursing one from
    /// `TransactionDetailView` cannot be reflected by `replace(_:)` alone —
    /// without this, a row's "quota" caption and advance cards would go
    /// stale the moment the user returns to the list.
    ///
    /// Parameters
    /// ----------
    /// advance:
    ///     The transaction's current advance, or `nil` once it has none
    ///     (deleted, or never had one).
    /// transactionID:
    ///     The transaction the advance belongs (or belonged) to.
    func updateAdvance(_ advance: AdvanceResponse?, for transactionID: UUID) {
        advancesByTransactionID[transactionID] = advance
    }
}
