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
        /// A `422` on rename: blank alias or too long. `APIError.badStatus`
        /// carries only the status code, not the `detail` reason
        /// (`tasks/backlog.md`), so the two causes are not distinguishable
        /// here — same collapsing `CategorizationViewModel.createCategory`
        /// already does for its own `422`.
        case invalidAlias
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

    /// Client used to reach the backend. `any APIClientProtocol` rather than
    /// the concrete `APIClient` (`.claude/rules/swift.md`), so a test can
    /// inject a fake.
    private let client: any APIClientProtocol

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

        do {
            let connections = try await client.connections()
            state = .loaded(connections)
        } catch {
            state = .failed
            return
        }

        if let fetchedAccounts = try? await accountsResult {
            accounts = fetchedAccounts
        }
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
