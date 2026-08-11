import Foundation
import Observation
import TraccioCore

/// Drives `AccountsView`: loads the account list from the backend and exposes
/// the current load state for the view to render.
///
/// All it does is call `APIClient` and hold the result — no derivation, no
/// business logic (that lives in the backend and in TraccioCore). Nothing here
/// logs or prints the models: they would carry account names, which are
/// sensitive (see `.claude/rules/data-safety.md`).
@MainActor
@Observable
final class AccountsViewModel {
    /// What the view should show right now.
    enum State {
        case idle
        case loading
        case loaded([AccountResponse])
        case failed
    }

    /// Current load state, observed by the view.
    private(set) var state: State = .idle

    /// Client used to reach the backend.
    private let client: APIClient

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to fetch accounts through. Defaults to a client
    ///     pointed at the local dev backend.
    init(client: APIClient = .devDefault) {
        self.client = client
    }

    /// Fetch the accounts and publish the outcome.
    ///
    /// A failure is surfaced as `.failed` without carrying the error into the
    /// UI — error details may reference the response and must not be shown or
    /// logged.
    func load() async {
        state = .loading
        do {
            let accounts = try await client.accounts()
            state = .loaded(accounts)
        } catch {
            state = .failed
        }
    }
}

extension APIClient {
    /// A client pointed at the local dev backend (`make run`).
    ///
    /// Hard-coded for M0 local development only; there is no configuration UI
    /// yet and no secrets are involved (the client has no notion of tokens).
    static let devDefault = APIClient(baseURL: URL(string: "http://localhost:8000")!)
}
