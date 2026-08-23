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
    /// Category id → name, used to label a row's `effectiveCategoryID`.
    /// Best-effort: a failure to fetch categories leaves this empty rather
    /// than failing the whole screen, since the transaction list is the
    /// primary content.
    private(set) var categoryNames: [UUID: String] = [:]
    /// Transaction id → its advance, for an advance-role row's "quota"
    /// caption and navigation to `AdvanceDetailView`. Best-effort, same
    /// reasoning as `categoryNames`.
    private(set) var advancesByTransactionID: [UUID: AdvanceResponse] = [:]
    /// Account id → the account, for `AdvanceDetailView`'s header line.
    /// Best-effort, same reasoning as `categoryNames`.
    private(set) var accountsByID: [UUID: AccountResponse] = [:]

    /// Client used to reach the backend.
    private let client: APIClient
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
    init(client: APIClient = .devDefault, pageSize: Int = 50) {
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

        do {
            let page = try await client.transactions(limit: pageSize, offset: 0)
            state = .loaded(page)
            offset = page.count
            reachedEnd = page.count < pageSize
        } catch {
            state = .failed
            return
        }

        if let categories = try? await categoriesResult {
            categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        }
        if let advances = try? await advancesResult {
            advancesByTransactionID = Dictionary(
                uniqueKeysWithValues: advances.map { ($0.transactionID, $0) }
            )
        }
        if let accounts = try? await accountsResult {
            accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
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
            let page = try await client.transactions(limit: pageSize, offset: offset)
            state = .loaded(current + page)
            offset += page.count
            reachedEnd = page.count < pageSize
        } catch {
            // Keep what's already on screen; the next scroll trigger retries.
        }
    }
}
