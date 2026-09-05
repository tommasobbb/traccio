import Foundation

/// A thin async client over the Traccio backend HTTP API.
///
/// This is where the client's networking lives — the app target only renders
/// what these methods return (see `client/CLAUDE.md`). The client has no notion
/// of *bank* tokens: it never stores or forwards a bank credential; those never
/// leave the backend. `apiToken` below is a different thing entirely — the
/// app's own shared secret for reaching its own backend (ADR 0014), sent as a
/// plain bearer header, never a bank credential.
///
/// The `URLSession` is injectable so tests can drive the client with a stub
/// transport (a `URLProtocol`) instead of hitting the network; a caller that
/// does not inject one gets `defaultSession`, which carries explicit timeouts
/// (see below) rather than `URLSessionConfiguration`'s 7-day resource default.
public struct APIClient: Sendable {
    /// Seconds a single request may stall — no bytes moving in either
    /// direction — before it fails. An idle timeout, reset whenever data
    /// arrives, so a slow-but-progressing response (a large sync) is fine;
    /// 30s of total silence is a wedged backend, not slowness.
    private static let requestTimeout: TimeInterval = 30
    /// Hard ceiling on a whole request/response including connection setup.
    /// Generous enough for the one genuinely long call (a first
    /// `POST /connections/{id}/sync` over years of history), short enough
    /// that a hung backend surfaces as an error in a couple of minutes
    /// instead of an indefinite spinner.
    private static let resourceTimeout: TimeInterval = 120

    /// The session used when a caller injects none: the default
    /// configuration plus the two timeouts above, and `waitsForConnectivity`
    /// left off so an offline request fails fast instead of parking until
    /// `resourceTimeout`. One shared instance — `URLSession` is thread-safe
    /// and reusing it is the intended usage.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Base URL the endpoints are resolved against, e.g. `http://localhost:8000`.
    private let baseURL: URL
    /// Sent as `Authorization: Bearer <apiToken>` on every request when set;
    /// omitted entirely when `nil` (a backend with no `TRACCIO_API_TOKEN`
    /// configured, e.g. local `make run`).
    private let apiToken: String?
    /// The session used for requests; defaults to `defaultSession`.
    private let session: URLSession

    /// Create a client.
    ///
    /// Parameters
    /// ----------
    /// baseURL:
    ///     Root the endpoint paths are appended to.
    /// apiToken:
    ///     The backend's shared API token, or `nil` if unconfigured — see
    ///     the type's doc comment.
    /// session:
    ///     Transport to use; inject a stubbed session in tests. Defaults to
    ///     `defaultSession` (explicit timeouts).
    public init(baseURL: URL, apiToken: String? = nil, session: URLSession = APIClient.defaultSession) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.session = session
    }

    /// Fetch the caller's accounts, oldest first.
    ///
    /// Returns
    /// -------
    /// The decoded accounts from `GET /accounts`.
    public func accounts() async throws -> [AccountResponse] {
        let envelope: AccountsResponse = try await get("accounts")
        return envelope.accounts
    }

    /// Set or clear an account's alias.
    ///
    /// Mirrors `POST /accounts/{id}/rename`, `200` with the account under its
    /// new alias. A `404` if the account is unknown or not the caller's; a
    /// `422` if the alias is blank (pass `nil` to clear it instead) or too
    /// long — the client does not pre-check either.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to rename.
    /// alias:
    ///     The new alias, or `nil` to clear it and fall back to the provider
    ///     name.
    ///
    /// Returns
    /// -------
    /// The account under its new alias.
    public func renameAccount(id: UUID, alias: String?) async throws -> AccountResponse {
        try await post("accounts/\(id.uuidString)/rename", body: RenameAccountRequest(alias: alias))
    }

    /// Set an account's colour and icon.
    ///
    /// Mirrors `POST /accounts/{id}/appearance`, `200` with the account under
    /// its new appearance. A full replace: both fields are sent together. A
    /// `404` if the account is unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to restyle.
    /// color:
    ///     The new colour, or `nil` to clear it.
    /// icon:
    ///     The new icon, or `nil` to clear it.
    ///
    /// Returns
    /// -------
    /// The account under its new appearance.
    public func setAccountAppearance(
        id: UUID, color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse {
        try await post(
            "accounts/\(id.uuidString)/appearance",
            body: SetAccountAppearanceRequest(color: color, icon: icon)
        )
    }

    /// Create a manual account — one with no bank behind it (ADR 0020).
    ///
    /// Mirrors `POST /accounts`, `201` with the created account (its
    /// `connectionID` is `nil`, its `source` is `.manual`). A `422` if the
    /// alias is blank or too long, or the currency/kind is not recognized —
    /// the client does not pre-check.
    ///
    /// Parameters
    /// ----------
    /// alias:
    ///     The account's name (e.g. "Contanti").
    /// kind:
    ///     What type of account it is — typically `.cash` or `.wallet`.
    /// currency:
    ///     The account's ISO 4217 currency.
    /// color:
    ///     Optional colour.
    /// icon:
    ///     Optional icon.
    ///
    /// Returns
    /// -------
    /// The created manual account.
    public func createManualAccount(
        alias: String, kind: AccountKind, currency: String,
        color: PaletteColor? = nil, icon: AccountIcon? = nil
    ) async throws -> AccountResponse {
        try await post(
            "accounts",
            body: CreateManualAccountRequest(
                alias: alias, kind: kind, currency: currency, color: color, icon: icon
            )
        )
    }

    /// Delete a manual account (ADR 0020).
    ///
    /// Mirrors `DELETE /accounts/{id}`, `204`. A `404` if the account is
    /// unknown or not the caller's; a `409 account_not_manual` if it is a
    /// synced account (removed only by the connection flow); a `409
    /// account_not_empty` if it still holds a transaction — delete those
    /// first. `APIError.badStatus(409)` does not distinguish the two `409`s;
    /// the caller checks whether the account is empty before offering this.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to delete.
    public func deleteAccount(id: UUID) async throws {
        try await delete("accounts/\(id.uuidString)")
    }

    /// Liveness probe; a cheap smoke test of the transport and base URL.
    ///
    /// Returns
    /// -------
    /// The decoded `GET /health` payload.
    public func health() async throws -> HealthResponse {
        try await get("health")
    }

    /// Summarize real spending and income over a period, per currency.
    ///
    /// Mirrors `GET /dashboard/summary` (`docs/decisions/
    /// 0007-dashboard-aggregation.md`). Both bounds are optional; omitting one
    /// leaves that side of the period open-ended. When supplied, `start` is
    /// inclusive and `end` is exclusive — a half-open interval, so the caller
    /// must pass the first instant of the day *after* the last day to
    /// include, not that day's midnight. `byBucket` is gap-filled across the
    /// whole period only when both bounds are given.
    ///
    /// `compareStart`/`compareEnd` must both be supplied or both omitted —
    /// the caller names *which* period to compare against (typically via its
    /// own `previous()`), not a boolean; the backend rejects exactly one
    /// being set with `422 incomplete_comparison_period`.
    ///
    /// Parameters
    /// ----------
    /// start:
    ///     Inclusive lower bound, or `nil` for open-ended.
    /// end:
    ///     Exclusive upper bound, or `nil` for open-ended.
    /// granularity:
    ///     How `byBucket` groups time. Defaults to one bucket per day.
    /// tz:
    ///     IANA timezone name bucketing happens in, or `nil` to let the
    ///     backend default to UTC.
    /// compareStart:
    ///     Inclusive lower bound of the comparison period, or `nil` for none.
    /// compareEnd:
    ///     Exclusive upper bound of the comparison period, or `nil` for none.
    ///
    /// Returns
    /// -------
    /// The decoded summary: one entry per currency with transactions in the
    /// period, never combined across currencies.
    public func dashboardSummary(
        start: Date? = nil,
        end: Date? = nil,
        granularity: BucketGranularity = .day,
        tz: String? = nil,
        compareStart: Date? = nil,
        compareEnd: Date? = nil
    ) async throws -> DashboardSummaryResponse {
        var query: [URLQueryItem] = []
        if let start {
            query.append(URLQueryItem(name: "start", value: TraccioCore.iso8601String(from: start)))
        }
        if let end {
            query.append(URLQueryItem(name: "end", value: TraccioCore.iso8601String(from: end)))
        }
        if granularity != .day {
            query.append(URLQueryItem(name: "granularity", value: granularity.rawValue))
        }
        if let tz {
            query.append(URLQueryItem(name: "tz", value: tz))
        }
        if let compareStart {
            query.append(
                URLQueryItem(name: "compare_start", value: TraccioCore.iso8601String(from: compareStart))
            )
        }
        if let compareEnd {
            query.append(
                URLQueryItem(name: "compare_end", value: TraccioCore.iso8601String(from: compareEnd))
            )
        }
        return try await get("dashboard/summary", query: query)
    }

    /// Fetch one transaction by id.
    ///
    /// Mirrors `GET /transactions/{id}`. Exists so a caller can re-fetch a
    /// single row's server-derived `effectiveAmount`/`effectiveCategoryID`
    /// after a write (e.g. confirming a category) without re-paginating the
    /// whole list — the backend still owns every derived value
    /// (`client/CLAUDE.md`).
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded transaction.
    public func transaction(id: UUID) async throws -> TransactionResponse {
        try await get("transactions/\(id.uuidString)")
    }

    /// Confirm a category on a transaction — the explicit user action.
    ///
    /// Mirrors `POST /transactions/{id}/category`, which returns `204 No
    /// Content` on success: the caller re-fetches via `transaction(id:)` to
    /// observe the new `effectiveCategoryID` rather than this method
    /// returning or inferring one.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to categorize.
    /// categoryID:
    ///     The category to confirm; must belong to the caller.
    public func confirmCategory(transactionID: UUID, categoryID: UUID) async throws {
        try await post(
            "transactions/\(transactionID.uuidString)/category",
            body: ConfirmCategoryRequest(categoryID: categoryID)
        )
    }

    /// Clear a transaction's confirmed category, falling back to any
    /// suggestion.
    ///
    /// Mirrors `POST`'s sibling `DELETE /transactions/{id}/category`, also
    /// `204 No Content`. Idempotent on the backend: clearing an already-clear
    /// transaction still succeeds.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to clear.
    public func clearCategory(transactionID: UUID) async throws {
        try await delete("transactions/\(transactionID.uuidString)/category")
    }

    /// Create a user-entered movement on a manual account (ADR 0020).
    ///
    /// Mirrors `POST /transactions`, `201` with the created transaction (it
    /// is always `booked`, `role == .personal`). A `404` if the account (or
    /// the optional category) is unknown or not the caller's; a `409
    /// account_not_manual` if the account is a synced one.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The movement's account, amount, currency, value date, description,
    ///     and optional category.
    ///
    /// Returns
    /// -------
    /// The created transaction, with the same derived fields
    /// `GET /transactions` returns.
    public func createManualTransaction(
        _ request: CreateManualTransactionRequest
    ) async throws -> TransactionResponse {
        try await post("transactions", body: request)
    }

    /// Edit a user-entered movement on a manual account (ADR 0020).
    ///
    /// Mirrors `POST /transactions/{id}/edit`, `200` with the transaction
    /// after the edit. A `404` if the transaction is unknown or not the
    /// caller's; a `409 transaction_not_manual` if it is on a synced account.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to edit.
    /// request:
    ///     The new movement fields (amount, currency, value date,
    ///     description).
    ///
    /// Returns
    /// -------
    /// The transaction after the edit.
    public func editManualTransaction(
        id: UUID, _ request: EditManualTransactionRequest
    ) async throws -> TransactionResponse {
        try await post("transactions/\(id.uuidString)/edit", body: request)
    }

    /// Delete a user-entered movement on a manual account (ADR 0020).
    ///
    /// Mirrors `DELETE /transactions/{id}`, `204`. A `404` if the transaction
    /// is unknown or not the caller's; a `409 transaction_not_manual` if it
    /// is on a synced account; a `409 transaction_in_use` if it is a leg of a
    /// transfer, advance, or reimbursement — unlink that first.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transaction to delete.
    public func deleteManualTransaction(id: UUID) async throws {
        try await delete("transactions/\(id.uuidString)")
    }

    /// Preview a file import without writing anything (ADR 0023).
    ///
    /// Mirrors `POST /imports/preview`. Every movement the file would create is
    /// classified `new` / `alreadyImported` / `invalid`; nothing is inserted.
    /// A `413` if the file is over the size limit; a `422` for a bad profile,
    /// missing columns, an undecodable file, or a needed-but-absent voucher
    /// account; a `409 account_not_manual` for a synced target account.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The target account(s), profile, filename, and base64 file content.
    ///
    /// Returns
    /// -------
    /// The per-movement classification and the counts.
    public func importPreview(
        _ request: ImportPreviewRequest
    ) async throws -> ImportPreviewResponse {
        try await post("imports/preview", body: request)
    }

    /// Commit a file import, inserting only the `new` movements (ADR 0023).
    ///
    /// Mirrors `POST /imports/commit` — same body and validation as
    /// `importPreview(_:)`. Running it twice on the same file adds nothing the
    /// second time (each movement's key is `"{profile}:{external_id}"`).
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The same body a preview takes.
    ///
    /// Returns
    /// -------
    /// How many movements were inserted, skipped as already present, and how
    /// many source rows were invalid.
    public func importCommit(
        _ request: ImportPreviewRequest
    ) async throws -> ImportCommitResponse {
        try await post("imports/commit", body: request)
    }

    /// Fetch the current user's settings (ADR 0024).
    ///
    /// Mirrors `GET /settings`. Only `tracking_start_date` so far — the day
    /// the dashboard and Movimenti begin from, or `nil` for no floor.
    public func settings() async throws -> TrackingStartResponse {
        try await get("settings")
    }

    /// Set or clear the tracking start date (ADR 0024).
    ///
    /// Mirrors `POST /settings`. `nil` clears the floor (show everything);
    /// either way nothing is deleted, only which movements are shown changes.
    /// Returns the value now stored.
    ///
    /// Parameters
    /// ----------
    /// date:
    ///     The new floor, or `nil` to clear it.
    public func setTrackingStart(_ date: CalendarDate?) async throws -> TrackingStartResponse {
        try await post("settings", body: SetTrackingStartRequest(trackingStartDate: date))
    }

    /// Fetch a suggested tracking start and the per-account first-movement
    /// dates it is derived from (ADR 0024).
    ///
    /// Mirrors `GET /settings/tracking-start/suggestion`.
    public func trackingStartSuggestion() async throws -> TrackingStartSuggestionResponse {
        try await get("settings/tracking-start/suggestion")
    }

    /// Fetch a page of the caller's transactions, most recent first.
    ///
    /// Mirrors `GET /transactions` (`docs/api/openapi.json`). Ordering,
    /// pagination bounds, and every filter all live on the backend; this
    /// method only shapes the request and decodes the result — filtering is
    /// never applied client-side against an already-fetched page (see
    /// `TransactionFilter`).
    ///
    /// Parameters
    /// ----------
    /// filter:
    ///     Which transactions to include. `.none` (the default) returns
    ///     every account, every category.
    /// limit:
    ///     Page size; the backend validates `1...200` and defaults to `50`.
    /// offset:
    ///     Number of rows to skip, for paging past the first page.
    ///
    /// Returns
    /// -------
    /// The decoded page of transactions, most recent first.
    public func transactions(
        filter: TransactionFilter = .none,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [TransactionResponse] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ] + filter.queryItems
        let envelope: TransactionsResponse = try await get("transactions", query: query)
        return envelope.transactions
    }

    /// Fetch the caller's categories.
    ///
    /// Returns
    /// -------
    /// The decoded categories from `GET /categories`.
    public func categories() async throws -> [CategoryResponse] {
        let envelope: CategoriesResponse = try await get("categories")
        return envelope.categories
    }

    /// Seed the caller's default category set.
    ///
    /// Mirrors `POST /categories/defaults` — the unblock for a category
    /// picker on a fresh database with no categories yet. Idempotent on the
    /// backend for categories already present.
    ///
    /// Returns
    /// -------
    /// The full set of categories after seeding.
    public func seedDefaultCategories() async throws -> [CategoryResponse] {
        let envelope: CategoriesResponse = try await post("categories/defaults")
        return envelope.categories
    }

    /// Create a category.
    ///
    /// Mirrors `POST /categories`, `201 Created` with the created category.
    /// The backend validates the name (blank/too-long → `422`) and uniqueness
    /// (a collision → `409 category_name_taken`); the client does not
    /// pre-check either. `parentID` nests the new category under an existing
    /// root (ADR 0018); a `404` if it is unknown, a `422
    /// category_depth_exceeded` if it is itself a child.
    ///
    /// Parameters
    /// ----------
    /// name:
    ///     The category's name.
    /// parentID:
    ///     The root to nest under, or `nil` to create a root.
    /// color:
    ///     The category's colour, or `nil` to let the backend default it.
    /// icon:
    ///     The category's icon, or `nil` to leave it unset.
    ///
    /// Returns
    /// -------
    /// The created category.
    public func createCategory(
        name: String, parentID: UUID? = nil, color: PaletteColor? = nil, icon: CategoryIcon? = nil
    ) async throws -> CategoryResponse {
        try await post(
            "categories",
            body: CreateCategoryRequest(name: name, parentID: parentID, color: color, icon: icon)
        )
    }

    /// Rename a category — its only mutation.
    ///
    /// Mirrors `POST /categories/{id}/rename`, `200` with the category under
    /// its new name. A `404` if the category is unknown or not the caller's;
    /// a `409 category_name_taken` if the new name collides with a different
    /// one of the caller's categories.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to rename.
    /// name:
    ///     The new name.
    ///
    /// Returns
    /// -------
    /// The category under its new name.
    public func renameCategory(id: UUID, name: String) async throws -> CategoryResponse {
        try await post("categories/\(id.uuidString)/rename", body: RenameCategoryRequest(name: name))
    }

    /// Set a category's colour and icon.
    ///
    /// Mirrors `POST /categories/{id}/appearance`, `200` with the category
    /// under its new appearance. A full replace: both fields are sent
    /// together. A `404` if the category is unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to restyle.
    /// color:
    ///     The new colour.
    /// icon:
    ///     The new icon, or `nil` to clear it.
    ///
    /// Returns
    /// -------
    /// The category under its new appearance.
    public func setCategoryAppearance(
        id: UUID, color: PaletteColor, icon: CategoryIcon?
    ) async throws -> CategoryResponse {
        try await post(
            "categories/\(id.uuidString)/appearance",
            body: SetCategoryAppearanceRequest(color: color, icon: icon)
        )
    }

    /// Reparent a category — make it a root, or nest it under one.
    ///
    /// Mirrors `POST /categories/{id}/move`, `200` with the category under
    /// its new parent. A `404` if the category, or the new parent, is
    /// unknown or not the caller's; a `422` if the new parent is the
    /// category itself or is itself a child (ADR 0018); a `409` if the
    /// category being moved has children of its own and a non-`nil` parent
    /// was given.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to move.
    /// parentID:
    ///     The new parent, or `nil` to make it a root.
    ///
    /// Returns
    /// -------
    /// The category under its new parent.
    public func moveCategory(id: UUID, parentID: UUID?) async throws -> CategoryResponse {
        try await post(
            "categories/\(id.uuidString)/move", body: MoveCategoryRequest(parentID: parentID)
        )
    }

    /// Delete a category.
    ///
    /// Mirrors `DELETE /categories/{id}`, `204 No Content` on success. A
    /// `404` if the category is unknown or not the caller's; a
    /// `409 category_in_use` if it is confirmed on any of the caller's
    /// transactions — that refusal is not something the client pre-checks,
    /// since only the backend knows every confirmation.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to delete.
    public func deleteCategory(id: UUID) async throws {
        try await delete("categories/\(id.uuidString)")
    }

    /// Fetch the caller's categorization rules, in evaluation order.
    ///
    /// Mirrors `GET /rules` (ADR 0005). The order is the order rules actually
    /// fire in (longest pattern wins) — not creation order, and never
    /// re-sorted client-side.
    ///
    /// Returns
    /// -------
    /// The decoded rules, in evaluation order (empty if none).
    public func rules() async throws -> [RuleResponse] {
        let envelope: RulesResponse = try await get("rules")
        return envelope.rules
    }

    /// Create a categorization rule.
    ///
    /// Mirrors `POST /rules`, `201 Created` with the created rule. A `404` if
    /// the target category is unknown or not the caller's; a `422` if the
    /// pattern is blank or too long; a `409 rule_already_exists` if the
    /// (normalized) `(matchKind, pattern)` collides with one of the caller's
    /// existing rules.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The target category, predicate, and pattern.
    ///
    /// Returns
    /// -------
    /// The created rule.
    public func createRule(_ request: CreateRuleRequest) async throws -> RuleResponse {
        try await post("rules", body: request)
    }

    /// Delete a categorization rule.
    ///
    /// Mirrors `DELETE /rules/{id}`, `204 No Content` on success. A `404` if
    /// the rule is unknown or not the caller's. Rules have no edit endpoint
    /// by design (ADR 0005): there is no update counterpart to this method.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The rule to delete.
    public func deleteRule(id: UUID) async throws {
        try await delete("rules/\(id.uuidString)")
    }

    /// Recompute every one of the caller's rules against every one of their
    /// transactions.
    ///
    /// Mirrors `POST /rules/apply`, `200` with counts. A full, idempotent
    /// recompute (ADR 0005) — never incremental — that writes only
    /// `suggested_category_id`, never `confirmed_category_id`. See
    /// `ApplyRulesResponse`'s docstring: the counts are a snapshot of the
    /// whole pool, not a change count.
    ///
    /// Returns
    /// -------
    /// How many rules were evaluated, and how many transactions ended up
    /// matched vs. cleared.
    public func applyRules() async throws -> ApplyRulesResponse {
        try await post("rules/apply")
    }

    /// Fetch the caller's advances.
    ///
    /// Returns
    /// -------
    /// The decoded advances from `GET /advances`, oldest first. Each carries
    /// the server-derived `receivable`/`reimbursed`/`outstanding`/`excess` —
    /// the client never recomputes these.
    public func advances() async throws -> [AdvanceResponse] {
        let envelope: AdvancesResponse = try await get("advances")
        return envelope.advances
    }

    /// Fetch one advance by id.
    ///
    /// Mirrors `GET /advances/{id}`. Used to re-fetch an advance's derived
    /// `reimbursed`/`outstanding`/`status` after recording a reimbursement,
    /// without re-fetching the whole list.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded advance.
    public func advance(id: UUID) async throws -> AdvanceResponse {
        try await get("advances/\(id.uuidString)")
    }

    /// Create an advance on a transaction — the explicit user action that
    /// marks money laid out on someone else's behalf.
    ///
    /// Mirrors `POST /advances`, `201 Created` with the created advance. Sets
    /// the transaction's `role` to `advance` server-side; the caller
    /// re-fetches it via `transaction(id:)` to observe the new
    /// `effectiveAmount`, same discipline as
    /// `confirmTransfer(outgoingID:incomingID:)`.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The transaction, the user's own share, and optional participants.
    ///
    /// Returns
    /// -------
    /// The created advance.
    public func createAdvance(_ request: CreateAdvanceRequest) async throws -> AdvanceResponse {
        try await post("advances", body: request)
    }

    /// Delete an advance and revert its transaction to `personal`.
    ///
    /// Mirrors `DELETE /advances/{id}`, `204 No Content` on success. The
    /// caller re-fetches the transaction via `transaction(id:)` to observe
    /// its restored `effectiveAmount`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to delete.
    public func deleteAdvance(id: UUID) async throws {
        try await delete("advances/\(id.uuidString)")
    }

    /// Write off an advance that will never be reimbursed.
    ///
    /// Mirrors `POST /advances/{id}/write-off`, `200` with the updated
    /// advance — `status` becomes `writtenOff` regardless of what is still
    /// outstanding.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to write off.
    ///
    /// Returns
    /// -------
    /// The updated advance.
    public func writeOffAdvance(id: UUID) async throws -> AdvanceResponse {
        try await post("advances/\(id.uuidString)/write-off")
    }

    /// Reopen a previously written-off advance.
    ///
    /// Mirrors `POST /advances/{id}/reopen`, `200` with the updated advance —
    /// the inverse of `writeOffAdvance(id:)`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The advance to reopen.
    ///
    /// Returns
    /// -------
    /// The updated advance.
    public func reopenAdvance(id: UUID) async throws -> AdvanceResponse {
        try await post("advances/\(id.uuidString)/reopen")
    }

    /// Record a reimbursement against an advance — either a manual cash entry
    /// or a link to an existing incoming transaction.
    ///
    /// Mirrors `POST /advances/{id}/reimbursements`, `201 Created` with the
    /// created reimbursement. A linked transaction's `role` becomes
    /// `reimbursement` server-side; the caller re-fetches it via
    /// `transaction(id:)` to observe the new `effectiveAmount`. The advance's
    /// derived `reimbursed`/`outstanding`/`status` are not on this response —
    /// re-fetch via `advance(id:)`.
    ///
    /// Parameters
    /// ----------
    /// advanceID:
    ///     The advance being paid back.
    /// request:
    ///     The amount, optional linked transaction, and optional note.
    ///
    /// Returns
    /// -------
    /// The created reimbursement.
    public func createReimbursement(
        advanceID: UUID,
        _ request: CreateReimbursementRequest
    ) async throws -> ReimbursementResponse {
        try await post("advances/\(advanceID.uuidString)/reimbursements", body: request)
    }

    /// Fetch an advance's reimbursements, oldest first.
    ///
    /// Mirrors `GET /advances/{id}/reimbursements`.
    ///
    /// Parameters
    /// ----------
    /// advanceID:
    ///     The advance whose reimbursements to list.
    ///
    /// Returns
    /// -------
    /// The decoded reimbursements (empty if none).
    public func reimbursements(advanceID: UUID) async throws -> [ReimbursementResponse] {
        let envelope: ReimbursementsResponse = try await get(
            "advances/\(advanceID.uuidString)/reimbursements"
        )
        return envelope.reimbursements
    }

    /// Delete a reimbursement and revert its linked transaction to `personal`,
    /// if it had one.
    ///
    /// Mirrors `DELETE /advances/{advanceID}/reimbursements/{id}`,
    /// `204 No Content` on success. The caller re-fetches the advance via
    /// `advance(id:)` to observe the reduced `reimbursed`/`outstanding`, and —
    /// when the deleted reimbursement carried a `transactionID` — that
    /// transaction via `transaction(id:)` to observe its restored
    /// `effectiveAmount`.
    ///
    /// Parameters
    /// ----------
    /// advanceID:
    ///     The advance the reimbursement belongs to.
    /// id:
    ///     The reimbursement to delete.
    public func deleteReimbursement(advanceID: UUID, id: UUID) async throws {
        try await delete("advances/\(advanceID.uuidString)/reimbursements/\(id.uuidString)")
    }

    /// Fetch the caller's bank connections, oldest first.
    ///
    /// Returns
    /// -------
    /// The decoded connections from `GET /connections`, each carrying the
    /// server-derived `consentState` and `daysUntilExpiry` — the client
    /// renders these and never recomputes them from `expiresAt`.
    public func connections() async throws -> [ConnectionResponse] {
        let envelope: ConnectionsResponse = try await get("connections")
        return envelope.connections
    }

    /// List the banks the caller can start a new connection with.
    ///
    /// Parameters
    /// ----------
    /// country:
    ///     ISO 3166-1 alpha-2 country to list institutions for.
    ///
    /// Returns
    /// -------
    /// The institutions offered in `country`, in the provider's own order.
    public func institutions(country: String) async throws -> [InstitutionResponse] {
        let envelope: InstitutionsResponse = try await get(
            "connections/institutions", query: [URLQueryItem(name: "country", value: country)]
        )
        return envelope.institutions
    }

    /// Start a new bank connection.
    ///
    /// Mirrors `POST /connections`: begins a fresh SCA round with the given
    /// institution rather than re-arming an existing connection.
    ///
    /// Parameters
    /// ----------
    /// institution:
    ///     The provider-scoped institution identifier, typically picked from
    ///     `institutions(country:)`.
    /// country:
    ///     ISO 3166-1 alpha-2 country the institution was offered in.
    /// logo:
    ///     The picked institution's `logo` URL, passed straight through so the
    ///     backend stores it on the connection for the Conti screen. `nil`
    ///     when the picker had none.
    ///
    /// Returns
    /// -------
    /// Where to send the user — open `authorizationURL` in the system
    /// browser, never an in-app `WebView`.
    public func startConnection(
        institution: String, country: String, logo: String? = nil
    ) async throws -> StartConnectionResponse {
        try await post(
            "connections",
            body: StartConnectionRequest(institution: institution, country: country, logo: logo)
        )
    }

    /// Sync a connection's accounts and transactions with the bank.
    ///
    /// The client's first write action: a real provider call with a real
    /// rate-limit budget (`docs/openbanking.md`), so this should only be
    /// invoked on a deliberate user action (a tap), never polled.
    ///
    /// Parameters
    /// ----------
    /// connectionID:
    ///     The connection to sync.
    ///
    /// Returns
    /// -------
    /// How many accounts and transactions were discovered and persisted. The
    /// data itself is read back via `accounts()`/`transactions(...)`.
    public func syncConnection(connectionID: UUID) async throws -> SyncResponse {
        try await post("connections/\(connectionID.uuidString)/sync")
    }

    /// Re-authorize a connection whose consent has lapsed or is close to it.
    ///
    /// Mirrors `POST /connections/{id}/reauthorize`: re-arms the existing
    /// connection with a fresh SCA round rather than creating a new one.
    ///
    /// Parameters
    /// ----------
    /// connectionID:
    ///     The connection to re-authorize.
    ///
    /// Returns
    /// -------
    /// Where to send the user — open `authorizationURL` in the system
    /// browser, never an in-app `WebView`.
    public func reauthorizeConnection(connectionID: UUID) async throws -> StartConnectionResponse {
        try await post("connections/\(connectionID.uuidString)/reauthorize")
    }

    /// Suggest transfers among the caller's transactions.
    ///
    /// Mirrors `GET /transfers/suggestions`. Detection only *suggests* — see
    /// `confirmTransfer(outgoingID:incomingID:)` for the write that acts on
    /// one. Each suggestion embeds both legs' full `TransactionResponse`, so
    /// rendering one needs no follow-up request per leg.
    ///
    /// Returns
    /// -------
    /// The suggested transfers, most confident first (empty if none).
    public func transferSuggestions() async throws -> [TransferSuggestionResponse] {
        let envelope: TransferSuggestionsResponse = try await get("transfers/suggestions")
        return envelope.suggestions
    }

    /// Fetch the caller's confirmed transfers, oldest first.
    ///
    /// Mirrors `GET /transfers`.
    ///
    /// Returns
    /// -------
    /// The decoded transfers.
    public func transfers() async throws -> [TransferResponse] {
        let envelope: TransfersResponse = try await get("transfers")
        return envelope.transfers
    }

    /// Confirm two transactions as a transfer — the explicit user action that
    /// turns a suggestion into a persisted link.
    ///
    /// Mirrors `POST /transfers/confirm`, which sets both legs' `role` to
    /// `transfer` and returns the created transfer. Both legs'
    /// `effectiveAmount` becomes zero as a result; the caller re-fetches them
    /// via `transaction(id:)` to observe that, same discipline as
    /// `confirmCategory(transactionID:categoryID:)`.
    ///
    /// Parameters
    /// ----------
    /// outgoingID:
    ///     Two-sided: the negative leg. Funded payment: the funding leg (set to
    ///     `role == .funding`).
    /// incomingID:
    ///     Two-sided: the positive leg. Funded payment: the funded leg — the
    ///     real expense, left `.personal`.
    /// kind:
    ///     `.twoSided` zeroes both legs; `.fundedPayment` zeroes only
    ///     `outgoingID`.
    ///
    /// Returns
    /// -------
    /// The created transfer.
    public func confirmTransfer(
        outgoingID: UUID, incomingID: UUID, kind: TransferKind
    ) async throws -> TransferResponse {
        try await post(
            "transfers/confirm",
            body: ConfirmTransferRequest(
                kind: kind, outgoingTransactionID: outgoingID, incomingTransactionID: incomingID
            )
        )
    }

    /// Reject a suggested pair so it is not suggested again.
    ///
    /// Mirrors `POST /transfers/reject`, `204 No Content` on success.
    /// Idempotent on the backend: rejecting the same pair twice changes
    /// nothing.
    ///
    /// Parameters
    /// ----------
    /// outgoingID:
    ///     One leg of the rejected pair (the suggestion's outgoing leg).
    /// incomingID:
    ///     The other leg of the rejected pair (the suggestion's incoming leg).
    public func rejectTransfer(outgoingID: UUID, incomingID: UUID) async throws {
        try await post(
            "transfers/reject",
            body: RejectTransferRequest(
                outgoingTransactionID: outgoingID, incomingTransactionID: incomingID
            )
        )
    }

    /// Delete a confirmed transfer and revert both legs to `personal`.
    ///
    /// Mirrors `DELETE /transfers/{id}`, `204 No Content` on success. The
    /// caller re-fetches both legs via `transaction(id:)` to observe their
    /// restored `effectiveAmount`.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The transfer to delete.
    public func deleteTransfer(id: UUID) async throws {
        try await delete("transfers/\(id.uuidString)")
    }

    /// Fetch the caller's events.
    ///
    /// Returns
    /// -------
    /// The decoded events from `GET /events`, oldest first. Each carries the
    /// server-derived `total`/`memberCount` — the client never recomputes
    /// these (an event is a reporting lens, not a role:
    /// `docs/domain.md` §Event).
    public func events() async throws -> [EventResponse] {
        let envelope: EventsResponse = try await get("events")
        return envelope.events
    }

    /// Fetch one event by id.
    ///
    /// Mirrors `GET /events/{id}`, `200` with the event. Used to re-fetch an
    /// event's derived `total`/`memberCount` after assigning or unassigning a
    /// member, without re-fetching the whole list. A `404` if the event is
    /// unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to fetch.
    ///
    /// Returns
    /// -------
    /// The decoded event.
    public func event(id: UUID) async throws -> EventResponse {
        try await get("events/\(id.uuidString)")
    }

    /// List an event's member transactions, most recent first.
    ///
    /// Mirrors `GET /events/{id}/transactions`, `200` with the transactions —
    /// unpaginated, since an event's members are a bounded set (unlike
    /// `transactions(accountID:limit:offset:)`'s unbounded pool). A `404` if
    /// the event is unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event whose members to list.
    ///
    /// Returns
    /// -------
    /// The event's member transactions (empty if none).
    public func eventTransactions(id: UUID) async throws -> [TransactionResponse] {
        let envelope: TransactionsResponse = try await get("events/\(id.uuidString)/transactions")
        return envelope.transactions
    }

    /// Create an event.
    ///
    /// Mirrors `POST /events`, `201 Created` with the created event. Starts
    /// `active`, with no members and a zero total.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The event's name and optional date range.
    ///
    /// Returns
    /// -------
    /// The created event.
    public func createEvent(_ request: CreateEventRequest) async throws -> EventResponse {
        try await post("events", body: request)
    }

    /// Delete an event, keeping its member transactions.
    ///
    /// Mirrors `DELETE /events/{id}`, `204 No Content` on success. Removes
    /// only the grouping — every member's `event_id` is cleared server-side,
    /// the transactions themselves are untouched. A `404` if the event is
    /// unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to delete.
    public func deleteEvent(id: UUID) async throws {
        try await delete("events/\(id.uuidString)")
    }

    /// Close an event.
    ///
    /// Mirrors `POST /events/{id}/close`, `200` with the updated event —
    /// `status` becomes `closed`. A `404` if the event is unknown or not the
    /// caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to close.
    ///
    /// Returns
    /// -------
    /// The updated event.
    public func closeEvent(id: UUID) async throws -> EventResponse {
        try await post("events/\(id.uuidString)/close")
    }

    /// Reopen a closed event.
    ///
    /// Mirrors `POST /events/{id}/reopen`, `200` with the updated event —
    /// `status` becomes `active`. A `404` if the event is unknown or not the
    /// caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The event to reopen.
    ///
    /// Returns
    /// -------
    /// The updated event.
    public func reopenEvent(id: UUID) async throws -> EventResponse {
        try await post("events/\(id.uuidString)/reopen")
    }

    /// Group a transaction under an event.
    ///
    /// Mirrors `POST /events/{id}/transactions`, `204 No Content` on success.
    /// Sets the transaction's `event_id` server-side — membership is a
    /// reporting lens and never changes its `role` or `effectiveAmount`. A
    /// `404` if the event or transaction is unknown or not the caller's; a
    /// `409` if the transaction already belongs to a *different* event (one
    /// event per transaction); re-assigning to the same event is idempotent.
    ///
    /// Parameters
    /// ----------
    /// eventID:
    ///     The event to group the transaction under.
    /// transactionID:
    ///     The transaction to assign. Must belong to the caller.
    public func assignTransaction(eventID: UUID, transactionID: UUID) async throws {
        try await post(
            "events/\(eventID.uuidString)/transactions",
            body: AssignTransactionRequest(transactionID: transactionID)
        )
    }

    /// Remove a transaction from an event.
    ///
    /// Mirrors `DELETE /events/{id}/transactions/{transaction_id}`, `204 No
    /// Content` on success. A `404` if the event is unknown or not the
    /// caller's, or if the transaction is not currently a member.
    ///
    /// Parameters
    /// ----------
    /// eventID:
    ///     The event to remove the transaction from.
    /// transactionID:
    ///     The transaction to unassign.
    public func unassignTransaction(eventID: UUID, transactionID: UUID) async throws {
        try await delete("events/\(eventID.uuidString)/transactions/\(transactionID.uuidString)")
    }

    /// Perform a request against `path` relative to `baseURL` and return the
    /// raw response body.
    ///
    /// The shared transport underneath every other private helper: URL
    /// assembly, the `URLSession` call, and the `HTTPURLResponse`/status
    /// check all happen exactly once here. Wraps every failure in an
    /// `APIError` so no framework error — which may carry a response body —
    /// propagates unchanged.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// method:
    ///     HTTP method to use.
    /// query:
    ///     Query items to append; an empty array (the default) produces a URL
    ///     with no `?` at all.
    /// body:
    ///     Raw request body, already encoded, or `nil` for none.
    ///
    /// Returns
    /// -------
    /// The raw, undecoded response body (empty for a `204 No Content`).
    private func send(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true
        ) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.badStatus(http.statusCode)
        }
        return data
    }

    /// Perform a `GET` for `path` relative to `baseURL` and decode the body.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// query:
    ///     Query items to append; an empty array (the default) produces a URL
    ///     with no `?` at all, matching the two-argument call sites exactly.
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, method: "GET", query: query)
        do {
            return try TraccioCore.jsonDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// Perform a `POST` for `path` relative to `baseURL` and decode the body.
    ///
    /// No request body: for a write that takes one, see the `Encodable`
    /// overload below.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    private func post<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(path, method: "POST")
        do {
            return try TraccioCore.jsonDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// Perform a `POST` for `path` with an encoded body, expecting no
    /// response body (`204 No Content`).
    ///
    /// Both category-confirmation endpoints answer this way; a variant that
    /// also decodes a `200` body is a separate addition for whenever a future
    /// write needs one.
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// body:
    ///     The request body to encode as JSON.
    private func post<Body: Encodable>(_ path: String, body: Body) async throws {
        let encoded: Data
        do {
            encoded = try TraccioCore.jsonEncoder().encode(body)
        } catch {
            throw APIError.encoding(underlying: error)
        }
        _ = try await send(path, method: "POST", body: encoded)
    }

    /// Perform a `POST` for `path` with an encoded body, decoding the
    /// response.
    ///
    /// The counterpart to the two overloads above, for a write that both
    /// sends and receives a body — `confirmTransfer(outgoingID:incomingID:)`
    /// is the first caller (`POST /transfers/confirm` answers `201` with the
    /// created transfer).
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    /// body:
    ///     The request body to encode as JSON.
    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let encoded: Data
        do {
            encoded = try TraccioCore.jsonEncoder().encode(body)
        } catch {
            throw APIError.encoding(underlying: error)
        }
        let data = try await send(path, method: "POST", body: encoded)
        do {
            return try TraccioCore.jsonDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// Perform a `DELETE` for `path`, expecting no response body (`204 No
    /// Content`).
    ///
    /// Parameters
    /// ----------
    /// path:
    ///     Endpoint path, relative to `baseURL`, with no leading slash.
    private func delete(_ path: String) async throws {
        _ = try await send(path, method: "DELETE")
    }
}
