import Foundation
import Observation
import TraccioCore

/// Drives `AccountsView`: loads connections (authoritative — they carry the
/// consent warning, the reason this screen exists) and accounts
/// (best-effort), and issues the client's first write actions — a manual
/// sync and re-authorization.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`client/CLAUDE.md`). Nothing here logs or prints a connection or account:
/// both carry institution/account names, sensitive per
/// `.claude/rules/data-safety.md`.
@MainActor
@Observable
final class AccountsViewModel {
    /// What the view should show right now.
    enum State {
        case idle
        case loading
        case loaded([ConnectionResponse])
        case failed
    }

    /// Why an in-flight sync or re-authorization failed, for the view to
    /// surface. Carries only a status-derived reason, never the response
    /// body — `APIError.badStatus` already drops it
    /// (`.claude/rules/data-safety.md`).
    enum ActionFailure: Equatable {
        case consentExpired(connectionID: UUID)
        case generic(connectionID: UUID)
    }

    /// Why an in-flight account rename/appearance update failed, for the
    /// view to surface. A separate type from `ActionFailure` — that one is
    /// keyed by `connectionID`, this one has no analogous key (an account
    /// update is scoped by the sheet presenting it, not a row the list
    /// itself tracks in-flight state for) — same reasoning as
    /// `CategorizationViewModel.ActionFailure` being its own type.
    enum AccountActionFailure: Equatable {
        /// A `422` on rename or manual-account create: blank alias or too
        /// long. `APIError.badStatus` carries only the status code, not the
        /// `detail` reason (`tasks/backlog.md`), so the two causes are not
        /// distinguishable here — same collapsing
        /// `CategorizationViewModel.createCategory` already does for its own
        /// `422`.
        case invalidAlias
        /// A `409 account_not_empty` on deleting a manual account (ADR 0020):
        /// it still holds movements, which must be deleted first. A `409
        /// account_not_manual` collapses to this too — the editor only
        /// offers delete for a manual account, so in practice it is always
        /// the "not empty" case.
        case accountNotEmpty
        case generic
    }

    /// Current load state, observed by the view. Connections are
    /// authoritative for this screen; accounts below are best-effort.
    private(set) var state: State = .idle
    /// Every account across every connection. The view pairs these with
    /// `state`'s connections via `TraccioCore.groupByConnection`. Best-effort:
    /// a failure to fetch accounts still leaves the consent cards worth
    /// rendering — same reasoning as `TransactionsViewModel.categoryNames`.
    private(set) var accounts: [AccountResponse] = []
    /// Whether the user's meal-vouchers setting is on (ADR 0029) — gates the
    /// "Buoni pasto" kind in the manual-account create/edit pickers.
    /// Best-effort, same posture as `accounts`: a failed fetch just leaves
    /// this `false`, hiding the kind rather than failing the whole screen.
    private(set) var mealVouchersEnabled = false
    /// Connection ids with a sync currently in flight, so a row can show a
    /// spinner. Unlike `TransactionsViewModel.isLoadingMore`, this must be
    /// observable — the view renders per-connection state from it.
    private(set) var syncing: Set<UUID> = []
    /// Connection ids currently re-authorizing (the browser round trip), so
    /// the "Rinnova ora" pill can show its own in-flight state independent of
    /// `syncing`.
    private(set) var reauthorizing: Set<UUID> = []
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?
    /// Increments once per successful manual sync — a `.sensoryFeedback(
    /// .success, trigger:)` trigger, not a count anyone reads.
    private(set) var successTick = 0
    /// Set while a rename/appearance write is in flight, so the editor
    /// sheet can disable its controls rather than let two writes race.
    private(set) var isSavingAccount = false
    /// The most recent account-update failure, if any, for the editor sheet
    /// to surface.
    private(set) var accountActionFailure: AccountActionFailure?
    /// Institutions offered for a new connection, as loaded by
    /// `loadInstitutions(country:)`. Plain best-effort state rather than its
    /// own `State` enum — a failed load just leaves this empty and
    /// `institutionsLoadFailed` set, same posture as `accounts`.
    private(set) var institutions: [InstitutionResponse] = []
    /// Set while `loadInstitutions(country:)` is in flight.
    private(set) var isLoadingInstitutions = false
    /// Whether the most recent `loadInstitutions(country:)` call failed.
    private(set) var institutionsLoadFailed = false
    /// Set while `startConnection(institution:country:)` is in flight, so the
    /// picker can disable its rows rather than let two starts race.
    private(set) var isStartingConnection = false
    /// Whether the most recent `startConnection(institution:country:)` call
    /// failed.
    private(set) var startConnectionFailed = false

    /// Client used to reach the backend. `any APIClientProtocol` rather than
    /// the concrete `APIClient` (`.claude/rules/swift.md`), so a test can
    /// inject a fake.
    private let client: any APIClientProtocol
    /// Set once `backfillLogosIfNeeded(_:)` has run, so the one-time
    /// provider-backed logo backfill is attempted at most once per launch —
    /// not on every `load()` (pull-to-refresh, post-sync reload).
    private var didAttemptLogoBackfill = false

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to fetch through. Defaults to a client pointed at
    ///     the local dev backend.
    init(client: any APIClientProtocol = APIClient.current) {
        self.client = client
    }

    /// Fetch connections and accounts, and publish the outcome.
    ///
    /// A connections failure is surfaced as `.failed` — the screen has
    /// nothing to show without them. An accounts failure leaves `accounts`
    /// empty rather than failing the whole screen: a card showing a consent
    /// warning with no account rows is still worth rendering.
    func load() async {
        state = .loading
        async let accountsResult = client.accounts()
        async let settingsResult = client.settings()

        do {
            let connections = try await client.connections()
            state = .loaded(connections)
            await backfillLogosIfNeeded(connections)
        } catch {
            state = .failed
            return
        }

        if let fetchedAccounts = try? await accountsResult {
            accounts = fetchedAccounts
        }
        if let fetchedSettings = try? await settingsResult {
            mealVouchersEnabled = fetchedSettings.mealVouchersEnabled
        }
    }

    /// One-time, best-effort: if any connection still has no institution logo
    /// (authorized before `institution_logo` was persisted), ask the backend
    /// to backfill it from the provider, and re-publish the connections if it
    /// filled any. Silent on failure — a lettermark is a fine fallback, so
    /// this must never turn into `.failed`.
    ///
    /// Parameters
    /// ----------
    /// connections:
    ///     The connections just loaded, checked for a missing logo.
    private func backfillLogosIfNeeded(_ connections: [ConnectionResponse]) async {
        guard !didAttemptLogoBackfill,
            connections.contains(where: { $0.institutionLogo == nil })
        else { return }
        didAttemptLogoBackfill = true

        guard let result = try? await client.backfillConnectionLogos(),
            result.updated > 0,
            let refreshed = try? await client.connections()
        else { return }
        state = .loaded(refreshed)
    }

    /// Sync one connection's accounts and transactions with the bank.
    ///
    /// A real provider call with a real rate-limit budget
    /// (`docs/openbanking.md`) — only ever invoked from a deliberate tap,
    /// never polled. Reloads on success, and on a `409 consent_expired` too,
    /// so the card re-renders with the "Rinnova" affordance the freshly
    /// derived `consentState` now calls for.
    ///
    /// Parameters
    /// ----------
    /// connectionID:
    ///     The connection to sync.
    func sync(connectionID: UUID) async {
        guard !syncing.contains(connectionID) else { return }
        syncing.insert(connectionID)
        defer { syncing.remove(connectionID) }
        actionFailure = nil

        do {
            _ = try await client.syncConnection(connectionID: connectionID)
            await load()
            successTick += 1
        } catch APIError.badStatus(409) {
            actionFailure = .consentExpired(connectionID: connectionID)
            await load()
        } catch {
            actionFailure = .generic(connectionID: connectionID)
        }
    }

    /// Re-authorize a connection whose consent has lapsed or is close to it.
    ///
    /// Parameters
    /// ----------
    /// connectionID:
    ///     The connection to re-authorize.
    ///
    /// Returns
    /// -------
    /// The URL to open in the system browser — never an in-app `WebView`
    /// (`.claude/rules/data-safety.md`) — or `nil` on failure, having already
    /// recorded `actionFailure`.
    func reauthorize(connectionID: UUID) async -> URL? {
        guard !reauthorizing.contains(connectionID) else { return nil }
        reauthorizing.insert(connectionID)
        defer { reauthorizing.remove(connectionID) }
        actionFailure = nil

        do {
            let result = try await client.reauthorizeConnection(connectionID: connectionID)
            return URL(string: result.authorizationURL)
        } catch {
            actionFailure = .generic(connectionID: connectionID)
            return nil
        }
    }

    /// Load the institutions offered for a new connection in `country`.
    ///
    /// Parameters
    /// ----------
    /// country:
    ///     ISO 3166-1 alpha-2 country to list institutions for.
    func loadInstitutions(country: String) async {
        isLoadingInstitutions = true
        defer { isLoadingInstitutions = false }
        institutionsLoadFailed = false

        do {
            institutions = try await client.institutions(country: country)
        } catch {
            institutions = []
            institutionsLoadFailed = true
        }
    }

    /// Start a new bank connection.
    ///
    /// Parameters
    /// ----------
    /// institution:
    ///     The institution the user picked, straight from `institutions`.
    ///     Its `name`/`country` drive the SCA start; its `logo` is passed
    ///     through so the backend stores it on the connection for Conti.
    ///
    /// Returns
    /// -------
    /// The URL to open in the system browser — never an in-app `WebView`
    /// (`.claude/rules/data-safety.md`) — or `nil` on failure, having already
    /// recorded `startConnectionFailed`.
    func startConnection(_ institution: InstitutionResponse) async -> URL? {
        guard !isStartingConnection else { return nil }
        isStartingConnection = true
        defer { isStartingConnection = false }
        startConnectionFailed = false

        do {
            let result = try await client.startConnection(
                institution: institution.name, country: institution.country, logo: institution.logo
            )
            return URL(string: result.authorizationURL)
        } catch {
            startConnectionFailed = true
            return nil
        }
    }

    /// Set or clear an account's alias.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to rename.
    /// alias:
    ///     The new alias, or `nil` to clear it and fall back to the provider
    ///     name.
    func renameAccount(id: UUID, alias: String?) async {
        await performAccountUpdate(onFailure: { $0 == 422 ? .invalidAlias : .generic }) { client in
            try await client.renameAccount(id: id, alias: alias)
        }
    }

    /// Set an account's colour and icon.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to restyle.
    /// color:
    ///     The new colour, or `nil` to clear it.
    /// icon:
    ///     The new icon, or `nil` to clear it.
    func setAccountAppearance(id: UUID, color: PaletteColor?, icon: AccountIcon?) async {
        await performAccountUpdate { client in
            try await client.setAccountAppearance(id: id, color: color, icon: icon)
        }
    }

    /// Reclassify a manual account's kind (ADR 0029) — e.g. Contanti →
    /// Buoni pasto. A `409` (the editor only offers this for a manual
    /// account, so in practice unreachable) collapses to `.generic`, same as
    /// any other failure.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to reclassify.
    /// kind:
    ///     The new kind.
    func setAccountKind(id: UUID, kind: AccountKind) async {
        await performAccountUpdate { client in
            try await client.setAccountKind(id: id, kind: kind)
        }
    }

    /// Create a manual account — one with no bank behind it (ADR 0020).
    ///
    /// On success the account is appended to `accounts` (its `connectionID`
    /// is `nil`, so `groupByConnection` files it under the "Conti manuali"
    /// group) and `successTick` bumps; the caller dismisses the sheet. A
    /// `422` surfaces as `.invalidAlias`, any other failure as `.generic`.
    ///
    /// Parameters
    /// ----------
    /// alias:
    ///     The account's name (e.g. "Contanti").
    /// kind:
    ///     What type of account it is.
    /// currency:
    ///     The account's ISO 4217 currency.
    /// color:
    ///     Optional colour.
    /// icon:
    ///     Optional icon.
    ///
    /// Returns
    /// -------
    /// `true` if the account was created, `false` otherwise (having recorded
    /// `accountActionFailure`).
    @discardableResult
    func createManualAccount(
        alias: String, kind: AccountKind, currency: String,
        color: PaletteColor?, icon: AccountIcon?
    ) async -> Bool {
        guard !isSavingAccount else { return false }
        isSavingAccount = true
        defer { isSavingAccount = false }
        accountActionFailure = nil

        do {
            let created = try await client.createManualAccount(
                alias: alias, kind: kind, currency: currency, color: color, icon: icon
            )
            accounts.append(created)
            successTick += 1
            return true
        } catch APIError.badStatus(422) {
            accountActionFailure = .invalidAlias
            return false
        } catch {
            accountActionFailure = .generic
            return false
        }
    }

    /// Delete a manual account (ADR 0020).
    ///
    /// On success the account is removed from `accounts`. A `409` means the
    /// account still holds movements (`.accountNotEmpty`); any other failure
    /// is `.generic`. The editor only offers this for a manual, so a `409
    /// account_not_manual` cannot realistically occur here.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to delete.
    ///
    /// Returns
    /// -------
    /// `true` if the account was deleted, `false` otherwise (having recorded
    /// `accountActionFailure`).
    @discardableResult
    func deleteManualAccount(id: UUID) async -> Bool {
        guard !isSavingAccount else { return false }
        isSavingAccount = true
        defer { isSavingAccount = false }
        accountActionFailure = nil

        do {
            try await client.deleteAccount(id: id)
            accounts.removeAll { $0.id == id }
            return true
        } catch APIError.badStatus(409) {
            accountActionFailure = .accountNotEmpty
            return false
        } catch {
            accountActionFailure = .generic
            return false
        }
    }

    /// Shared shape for the two writes above: guard against overlap, run the
    /// write, and on success replace just the updated account in `accounts`
    /// with what the backend returned — never a client-computed value, same
    /// posture as `CategorizationViewModel.performUpdate`, but a targeted
    /// replace rather than a full `load()` since a rename/appearance change
    /// cannot affect any connection.
    ///
    /// Parameters
    /// ----------
    /// mapFailure:
    ///     Maps a failed request's HTTP status code (`nil` for a non-HTTP
    ///     failure) to the reason the sheet should show. Defaults to always
    ///     reporting `.generic`.
    /// write:
    ///     The write to perform, given the client; returns the updated
    ///     account.
    private func performAccountUpdate(
        onFailure mapFailure: (Int?) -> AccountActionFailure = { _ in .generic },
        _ write: (any APIClientProtocol) async throws -> AccountResponse
    ) async {
        guard !isSavingAccount else { return }
        isSavingAccount = true
        defer { isSavingAccount = false }
        accountActionFailure = nil

        do {
            let updated = try await write(client)
            if let index = accounts.firstIndex(where: { $0.id == updated.id }) {
                accounts[index] = updated
            }
        } catch APIError.badStatus(let code) {
            accountActionFailure = mapFailure(code)
        } catch {
            accountActionFailure = mapFailure(nil)
        }
    }
}
