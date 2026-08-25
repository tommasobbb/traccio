import Foundation
import TraccioCore

extension APIClient {
    /// The client configured from `ServerConfigurationStore` — the base URL
    /// and API token set in Impostazioni ▸ Server (ADR 0014), or
    /// `http://localhost:8000` with no token if nothing has been configured
    /// yet (M0/M3 local `make run` development, unchanged from before this
    /// was configurable).
    ///
    /// A computed property, not a cached constant: every view model's
    /// `= APIClient.current` default parameter re-evaluates this on each
    /// call, so a value saved in Settings takes effect for any view model
    /// created afterward. Every tab is constructed once, at app launch,
    /// though — an already-running screen does not pick up a change until
    /// the app is relaunched. `ServerSettingsViewModel` builds its own
    /// ad-hoc client from the just-entered fields for "Verifica e salva"
    /// rather than relying on this, so the check itself is never stale.
    static var current: APIClient {
        let configuration = ServerConfigurationStore.shared.load()
        return APIClient(baseURL: configuration.baseURL, apiToken: configuration.apiToken)
    }
}
