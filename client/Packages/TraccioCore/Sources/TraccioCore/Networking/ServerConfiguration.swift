import Foundation

/// Where the client points, and what it authenticates with — the base URL
/// and API token set in Impostazioni ▸ Server (ADR 0014). Not persisted
/// itself; `ServerConfigurationStore` owns that.
public struct ServerConfiguration: Equatable, Sendable {
    public var baseURL: URL
    /// `nil` when the backend has no `TRACCIO_API_TOKEN` configured (e.g.
    /// local `make run`) — a real, valid state, not "not yet loaded".
    public var apiToken: String?

    public init(baseURL: URL, apiToken: String? = nil) {
        self.baseURL = baseURL
        self.apiToken = apiToken
    }
}

/// The seam `APIClient.current` (`App/Sources/APIClient+Default.swift`) and
/// `ServerSettingsViewModel` depend on, so a test can inject an in-memory
/// fake instead of touching real `UserDefaults`/Keychain.
public protocol ServerConfigurationStoring: Sendable {
    func load() -> ServerConfiguration
    func save(_ configuration: ServerConfiguration)
    /// Whether `save` has ever succeeded — distinct from `load()` always
    /// returning *some* configuration, since a fresh install's zero-config
    /// default is itself a valid value, not a sentinel for "unset". Onboarding
    /// (`OnboardingView`) uses this to show the first-run setup screen only
    /// once, not every time the default happens to still be in effect.
    var isConfigured: Bool { get }
}

/// The production `ServerConfigurationStoring`: the base URL in
/// `UserDefaults` (not financial data — `.claude/rules/data-safety.md`'s
/// restriction is narrower than "no `UserDefaults` at all", same reasoning
/// as the biometric-lock toggle), the token in the Keychain via
/// `APITokenStoring`.
public struct ServerConfigurationStore: ServerConfigurationStoring {
    /// Matches the value `APIClient+Dev.swift` hardcoded before ADR 0014, so
    /// a fresh install with nothing configured still points at local
    /// `make run` — zero-config local development is unchanged.
    public static let defaultBaseURL = URL(string: "http://localhost:8000")!

    public static let shared = ServerConfigurationStore()

    private static let baseURLDefaultsKey = "server.baseURL"
    private static let configuredDefaultsKey = "server.configured"

    // UserDefaults is not (yet) Sendable-annotated in the SDK despite being
    // documented thread-safe — trusted rather than boxed in `@unchecked
    // Sendable` for the whole struct.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let tokenStore: any APITokenStoring

    public init(
        defaults: UserDefaults = .standard,
        tokenStore: any APITokenStoring = KeychainAPITokenStore()
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
    }

    public var isConfigured: Bool {
        defaults.bool(forKey: Self.configuredDefaultsKey)
    }

    public func load() -> ServerConfiguration {
        let baseURL =
            defaults.string(forKey: Self.baseURLDefaultsKey).flatMap(URL.init(string:))
            ?? Self.defaultBaseURL
        return ServerConfiguration(baseURL: baseURL, apiToken: tokenStore.load())
    }

    public func save(_ configuration: ServerConfiguration) {
        defaults.set(configuration.baseURL.absoluteString, forKey: Self.baseURLDefaultsKey)
        defaults.set(true, forKey: Self.configuredDefaultsKey)
        if let token = configuration.apiToken, !token.isEmpty {
            tokenStore.save(token)
        } else {
            tokenStore.delete()
        }
    }
}
