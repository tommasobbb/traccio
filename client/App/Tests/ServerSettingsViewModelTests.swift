import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// An in-memory `ServerConfigurationStoring` so these tests never touch
/// `UserDefaults` or the Keychain.
private final class FakeServerConfigurationStore: ServerConfigurationStoring, @unchecked Sendable {
    var saved: ServerConfiguration?
    private let initial: ServerConfiguration

    init(initial: ServerConfiguration) {
        self.initial = initial
    }

    var isConfigured: Bool { saved != nil }
    func load() -> ServerConfiguration { saved ?? initial }
    func save(_ configuration: ServerConfiguration) { saved = configuration }
}

/// Tests for `ServerSettingsViewModel` against `FakeAPIClient` — no network
/// stub needed, per `docs/engineering.md`'s "test the seam." Fixtures are
/// synthetic (`docs/engineering.md`).
@MainActor
struct ServerSettingsViewModelTests {
    private static let initialConfiguration = ServerConfiguration(
        baseURL: URL(string: "http://localhost:8000")!, apiToken: nil
    )

    @Test func initPrefillsFieldsFromTheStore() {
        let store = FakeServerConfigurationStore(
            initial: ServerConfiguration(
                baseURL: URL(string: "https://traccio.example.com")!, apiToken: "SAVED-TOKEN-01"
            )
        )

        let model = ServerSettingsViewModel(store: store, makeClient: { _, _ in FakeAPIClient() })

        #expect(model.baseURLText == "https://traccio.example.com")
        #expect(model.apiTokenText == "SAVED-TOKEN-01")
    }

    @Test func verifyAndSaveWithAnInvalidURLFailsWithoutCallingTheClient() async {
        let store = FakeServerConfigurationStore(initial: Self.initialConfiguration)
        let model = ServerSettingsViewModel(store: store, makeClient: { _, _ in FakeAPIClient() })
        model.baseURLText = "not a url"

        await model.verifyAndSave()

        #expect(model.state == .failure("URL non valido."))
        #expect(store.saved == nil)
    }

    @Test func verifyAndSaveSucceedsAndPersistsWhenBothCallsSucceed() async {
        let store = FakeServerConfigurationStore(initial: Self.initialConfiguration)
        let fake = FakeAPIClient()
        let model = ServerSettingsViewModel(store: store, makeClient: { _, _ in fake })
        model.baseURLText = "https://traccio.example.com"
        model.apiTokenText = "NEW-TOKEN-01"

        await model.verifyAndSave()

        #expect(model.state == .success)
        #expect(store.saved?.baseURL == URL(string: "https://traccio.example.com")!)
        #expect(store.saved?.apiToken == "NEW-TOKEN-01")
    }

    @Test func verifyAndSaveWithAnEmptyTokenFieldSavesANilToken() async {
        let store = FakeServerConfigurationStore(initial: Self.initialConfiguration)
        let fake = FakeAPIClient()
        let model = ServerSettingsViewModel(store: store, makeClient: { _, _ in fake })
        model.baseURLText = "https://traccio.example.com"
        model.apiTokenText = ""

        await model.verifyAndSave()

        #expect(model.state == .success)
        #expect(store.saved?.apiToken == nil)
    }

    @Test func verifyAndSaveFailsWhenHealthIsUnreachableAndDoesNotSave() async {
        let store = FakeServerConfigurationStore(initial: Self.initialConfiguration)
        let fake = FakeAPIClient()
        await fake.setHealthError(APIError.transport(underlying: URLError(.cannotConnectToHost)))
        let model = ServerSettingsViewModel(store: store, makeClient: { _, _ in fake })
        model.baseURLText = "https://traccio.example.com"

        await model.verifyAndSave()

        #expect(model.state == .failure("Server non raggiungibile."))
        #expect(store.saved == nil)
    }

    @Test func verifyAndSaveFailsWithATokenSpecificMessageOn401() async {
        let store = FakeServerConfigurationStore(initial: Self.initialConfiguration)
        let fake = FakeAPIClient()
        await fake.setAccountsError(APIError.unauthorized)
        let model = ServerSettingsViewModel(store: store, makeClient: { _, _ in fake })
        model.baseURLText = "https://traccio.example.com"
        model.apiTokenText = "WRONG-TOKEN-01"

        await model.verifyAndSave()

        #expect(model.state == .failure("Token non valido."))
        #expect(store.saved == nil)
    }
}
