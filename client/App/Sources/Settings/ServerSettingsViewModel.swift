import Foundation
import TraccioCore

/// Backs the "Server" section of `SettingsView` — the base URL and API token
/// (ADR 0014) that used to be hardcoded in `APIClient+Dev.swift`.
///
/// "Verifica e salva" builds an ad-hoc client from whatever is currently
/// typed (via `makeClient`, injected so a test never hits the network) and
/// only persists through `store` once both a plain `GET /health` and an
/// authenticated call have actually succeeded — so a saved configuration is
/// never one the app hasn't already proven works.
@MainActor @Observable
final class ServerSettingsViewModel {
    /// Illegal states unrepresentable: there is no bare `Bool` for "loading"
    /// crossed with a separate optional error string.
    enum VerificationState: Equatable {
        case idle
        case checking
        case success
        case failure(String)
    }

    var baseURLText: String
    var apiTokenText: String
    private(set) var state: VerificationState = .idle

    private let store: any ServerConfigurationStoring
    private let makeClient: @Sendable (URL, String?) -> any APIClientProtocol

    /// Create the view model, pre-filling the fields from whatever is
    /// already saved.
    ///
    /// Parameters
    /// ----------
    /// store:
    ///     Where the configuration is read from and, on success, saved to.
    ///     Defaults to the real `ServerConfigurationStore`; a test injects
    ///     an in-memory fake.
    /// makeClient:
    ///     Builds the client "Verifica e salva" checks against, from the
    ///     currently typed URL and token — never `APIClient.current`, which
    ///     would only reflect what was already saved. Defaults to a plain
    ///     `APIClient`; a test injects a closure returning `FakeAPIClient`.
    init(
        store: any ServerConfigurationStoring = ServerConfigurationStore.shared,
        makeClient: @escaping @Sendable (URL, String?) -> any APIClientProtocol = {
            APIClient(baseURL: $0, apiToken: $1)
        }
    ) {
        self.store = store
        self.makeClient = makeClient
        let configuration = store.load()
        self.baseURLText = configuration.baseURL.absoluteString
        self.apiTokenText = configuration.apiToken ?? ""
    }

    /// Validate the typed URL, exercise it against the real backend, and
    /// persist it only once that succeeds.
    func verifyAndSave() async {
        let trimmedURLText = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURLText), url.scheme != nil, url.host != nil else {
            state = .failure("URL non valido.")
            return
        }
        state = .checking

        let token = apiTokenText.isEmpty ? nil : apiTokenText
        let client = makeClient(url, token)
        do {
            _ = try await client.health()
        } catch {
            state = .failure("Server non raggiungibile.")
            return
        }
        do {
            _ = try await client.accounts()
        } catch APIError.unauthorized {
            state = .failure("Token non valido.")
            return
        } catch {
            state = .failure("Server non raggiungibile.")
            return
        }

        store.save(ServerConfiguration(baseURL: url, apiToken: token))
        state = .success
    }
}
