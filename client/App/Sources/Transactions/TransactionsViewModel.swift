import Foundation
import Observation
import TraccioCore

/// Drives `TransactionsView`: loads a page of transactions plus the
/// category/advance/account data needed to label and link them, and pages in
/// more as the user scrolls.
///
/// All it does is call `APIClient` and hold the result — no derivation, no
/// arithmetic (that lives in the backend, per `client/CLAUDE.md`). Nothing
/// here logs or prints a transaction: rows carry amounts, raw bank
/// descriptions, and counterparty names, all sensitive
/// (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class TransactionsViewModel {
    /// What the view should show right now.
    enum State {
        case idle
        case loading
        case loaded([TransactionResponse])
        case failed
    }

    /// Current load state, observed by the view.
    private(set) var state: State = .idle
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

    /// Client used to reach the backend. `any APIClientProtocol` rather than
    /// the concrete `APIClient` (`.claude/rules/swift.md`), so a test can
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

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to fetch through. Defaults to a client pointed at
    ///     the local dev backend.
    /// pageSize:
    ///     Transactions requested per page.
    init(client: any APIClientProtocol = APIClient.current, pageSize: Int = 50) {
        self.client = client
        self.pageSize = pageSize
    }

    /// Fetch the first page of transactions plus the category/advance/account
    /// data, and publish the outcome. Resets any pagination state from a
    /// prior load.
    ///
    /// A failure is surfaced as `.failed` without carrying the error into the
    /// UI — error details may reference the response and must not be shown
    /// or logged.
    func load() async {
        state = .loading
        offset = 0
        reachedEnd = false

        async let categoriesResult = client.categories()
        async let advancesResult = client.advances()
        async let accountsResult = client.accounts()
        async let transferSuggestionsResult = client.transferSuggestions()
        async let transfersResult = client.transfers()
        async let eventsResult = client.events()

        do {
            let page = try await client.transactions(filter: filter, limit: pageSize, offset: 0)
            state = .loaded(page)
            offset = page.count
            reachedEnd = page.count < pageSize
        } catch {
            state = .failed
            return
        }

        if let fetchedCategories = try? await categoriesResult {
            categories = fetchedCategories
            categoryNames = Dictionary(uniqueKeysWithValues: fetchedCategories.map { ($0.id, $0.name) })
            categoriesByID = Dictionary(uniqueKeysWithValues: fetchedCategories.map { ($0.id, $0) })
        }
        if let advances = try? await advancesResult {
            advancesByTransactionID = Dictionary(
                uniqueKeysWithValues: advances.map { ($0.transactionID, $0) }
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
    /// server-derived `effectiveCategoryID` — see `client/CLAUDE.md`) and
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

    /// Change the active filter and reload from the first page.
    ///
    /// Always resets `offset`/`reachedEnd` — a different filter means a
    /// different result set, so any already-loaded page is stale. `load()`
    /// itself does the same reset; this just also updates `filter` first, so
    /// both entry points share one reload path.
    ///
    /// Parameters
    /// ----------
    /// newFilter:
    ///     The filter to apply from now on, including to `loadMore()`.
    func applyFilter(_ newFilter: TransactionFilter) async {
        filter = newFilter
        await load()
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
