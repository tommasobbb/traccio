import Foundation
import Testing

@testable import TraccioCore

/// An in-memory `APITokenStoring` so these tests never touch the real
/// Keychain — `KeychainAPITokenStore` itself is exercised only by manual
/// verification (Keychain access from a sandboxed `swift test` process is
/// not reliable to assert on in CI).
private final class InMemoryTokenStore: APITokenStoring, @unchecked Sendable {
    var stored: String?
    func load() -> String? { stored }
    func save(_ token: String) { stored = token }
    func delete() { stored = nil }
}

struct ServerConfigurationTests {
    private func makeStore() -> (ServerConfigurationStore, InMemoryTokenStore) {
        let defaults = UserDefaults(suiteName: "ServerConfigurationTests.\(UUID())")!
        let tokenStore = InMemoryTokenStore()
        return (ServerConfigurationStore(defaults: defaults, tokenStore: tokenStore), tokenStore)
    }

    @Test func loadWithNothingSavedReturnsTheDefaultLocalBaseURLAndNoToken() {
        let (store, _) = makeStore()

        let configuration = store.load()

        #expect(configuration.baseURL == ServerConfigurationStore.defaultBaseURL)
        #expect(configuration.apiToken == nil)
    }

    @Test func saveThenLoadRoundTripsBothFields() {
        let (store, _) = makeStore()
        let url = URL(string: "https://traccio.example.com")!

        store.save(ServerConfiguration(baseURL: url, apiToken: "TEST-TOKEN-01"))
        let loaded = store.load()

        #expect(loaded.baseURL == url)
        #expect(loaded.apiToken == "TEST-TOKEN-01")
    }

    @Test func savingAnEmptyTokenDeletesAnyPreviouslyStoredOne() {
        let (store, tokenStore) = makeStore()
        let url = URL(string: "https://traccio.example.com")!
        store.save(ServerConfiguration(baseURL: url, apiToken: "TEST-TOKEN-01"))

        store.save(ServerConfiguration(baseURL: url, apiToken: ""))

        #expect(tokenStore.stored == nil)
        #expect(store.load().apiToken == nil)
    }

    @Test func savingANilTokenDeletesAnyPreviouslyStoredOne() {
        let (store, tokenStore) = makeStore()
        let url = URL(string: "https://traccio.example.com")!
        store.save(ServerConfiguration(baseURL: url, apiToken: "TEST-TOKEN-01"))

        store.save(ServerConfiguration(baseURL: url, apiToken: nil))

        #expect(tokenStore.stored == nil)
        #expect(store.load().apiToken == nil)
    }
}
