import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `AccountsViewModel` against `FakeAPIClient` — no network stub
/// needed, per `.claude/rules/swift.md`'s "test the seam." Closes the
/// zero-test gap this view model previously had (`tasks/backlog.md`).
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented ids, a
/// round hash, no real bank data.
@MainActor
struct AccountsViewModelTests {
    private static let accountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static func makeAccount(
        id: UUID = accountID,
        connectionID: UUID? = UUID(),
        source: AccountSource = .synced,
        kind: AccountKind = .current,
        name: String? = "TEST CURRENT 01",
        alias: String? = nil,
        displayName: String? = "TEST CURRENT 01",
        color: PaletteColor? = nil,
        icon: AccountIcon? = nil
    ) -> AccountResponse {
        AccountResponse(
            id: id,
            connectionID: connectionID,
            source: source,
            kind: kind,
            currency: "EUR",
            name: name,
            alias: alias,
            displayName: displayName,
            color: color,
            icon: icon,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    private static func makeConnection(
        id: UUID = UUID(), institutionLogo: String? = nil
    ) -> ConnectionResponse {
        ConnectionResponse(
            id: id,
            provider: "enable_banking",
            institutionName: "TEST BANK 01",
            institutionLogo: institutionLogo,
            status: .active,
            consentState: .active,
            daysUntilExpiry: 60,
            expiresAt: Date(timeIntervalSince1970: 1_760_000_000),
            createdAt: Date(timeIntervalSince1970: 1_755_000_000),
            lastSyncedAt: nil,
            backgroundSyncEnabled: false,
            syncBudgetRemaining: nil,
            nextSyncAt: nil
        )
    }

    @Test func loadPublishesAccountsAlongsideConnections() async throws {
        let client = FakeAPIClient()
        await client.setAccounts([Self.makeAccount()])
        let model = AccountsViewModel(client: client)

        await model.load()

        guard case .loaded = model.state else {
            Issue.record("expected .loaded after load()")
            return
        }
        #expect(model.accounts.map(\.id) == [Self.accountID])
    }

    @Test func loadBackfillsLogosOnceWhenAConnectionIsMissingOne() async throws {
        let client = FakeAPIClient()
        await client.setConnectionsToReturn([Self.makeConnection(institutionLogo: nil)])
        await client.setBackfillConnectionLogosResult(BackfillLogosResponse(updated: 1))
        let model = AccountsViewModel(client: client)

        await model.load()
        await model.load()

        // Backfill is attempted exactly once, and a non-zero result triggers
        // one extra connections re-fetch to pick up the filled logo.
        #expect(await client.backfillConnectionLogosCallCount == 1)
        #expect(await client.connectionsFetchCount == 3)  // load, re-fetch, load
    }

    @Test func loadDoesNotBackfillWhenEveryConnectionHasALogo() async throws {
        let client = FakeAPIClient()
        await client.setConnectionsToReturn([
            Self.makeConnection(institutionLogo: "https://logos.example.test/tb01/")
        ])
        let model = AccountsViewModel(client: client)

        await model.load()

        #expect(await client.backfillConnectionLogosCallCount == 0)
    }

    @Test func loadSurvivesABackfillFailure() async throws {
        let client = FakeAPIClient()
        await client.setConnectionsToReturn([Self.makeConnection(institutionLogo: nil)])
        await client.setBackfillConnectionLogosError(FakeAPIError())
        let model = AccountsViewModel(client: client)

        await model.load()

        guard case .loaded = model.state else {
            Issue.record("a backfill failure must not fail the screen")
            return
        }
    }

    @Test func renameAccountReplacesTheAccountInPlaceWithTheServerResult() async throws {
        let client = FakeAPIClient()
        await client.setAccounts([Self.makeAccount(alias: nil, displayName: "TEST CURRENT 01")])
        let model = AccountsViewModel(client: client)
        await model.load()
        await client.setRenameAccountResult(
            Self.makeAccount(alias: "My salary account", displayName: "My salary account")
        )

        await model.renameAccount(id: Self.accountID, alias: "My salary account")

        #expect(model.accountActionFailure == nil)
        #expect(model.accounts.first?.alias == "My salary account")
        let recorded = await client.renamedAccounts
        #expect(recorded == [.init(id: Self.accountID, alias: "My salary account")])
    }

    @Test func renameAccountOn422SurfacesInvalidAliasAndLeavesAccountsUntouched() async throws {
        let client = FakeAPIClient()
        let original = Self.makeAccount(alias: nil)
        await client.setAccounts([original])
        let model = AccountsViewModel(client: client)
        await model.load()
        await client.setRenameAccountError(APIError.badStatus(422))

        await model.renameAccount(id: Self.accountID, alias: "   ")

        #expect(model.accountActionFailure == .invalidAlias)
        #expect(model.accounts.first == original)
    }

    @Test func renameAccountOnGenericFailureSurfacesGeneric() async throws {
        let client = FakeAPIClient()
        await client.setAccounts([Self.makeAccount()])
        let model = AccountsViewModel(client: client)
        await model.load()
        await client.setRenameAccountError(FakeAPIError())

        await model.renameAccount(id: Self.accountID, alias: "New alias")

        #expect(model.accountActionFailure == .generic)
    }

    @Test func setAccountAppearanceReplacesTheAccountInPlace() async throws {
        let client = FakeAPIClient()
        await client.setAccounts([Self.makeAccount(color: nil, icon: nil)])
        let model = AccountsViewModel(client: client)
        await model.load()
        await client.setAccountAppearanceResult(Self.makeAccount(color: .teal, icon: .savings))

        await model.setAccountAppearance(id: Self.accountID, color: .teal, icon: .savings)

        #expect(model.accountActionFailure == nil)
        #expect(model.accounts.first?.color == .teal)
        #expect(model.accounts.first?.icon == .savings)
        let recorded = await client.accountAppearanceUpdates
        #expect(recorded == [.init(id: Self.accountID, color: .teal, icon: .savings)])
    }

    @Test func loadInstitutionsPublishesTheInstitutionsForTheGivenCountry() async throws {
        let client = FakeAPIClient()
        await client.setInstitutions([InstitutionResponse(name: "TEST BANK 01", country: "IT")])
        let model = AccountsViewModel(client: client)

        await model.loadInstitutions(country: "IT")

        #expect(model.institutionsLoadFailed == false)
        #expect(model.institutions.map(\.name) == ["TEST BANK 01"])
        let recorded = await client.receivedInstitutionsCountries
        #expect(recorded == ["IT"])
    }

    @Test func loadInstitutionsOnFailureClearsInstitutionsAndSetsLoadFailed() async throws {
        let client = FakeAPIClient()
        await client.setInstitutions([InstitutionResponse(name: "TEST BANK 01", country: "IT")])
        let model = AccountsViewModel(client: client)
        await model.loadInstitutions(country: "IT")
        await client.setInstitutionsError(FakeAPIError())

        await model.loadInstitutions(country: "IT")

        #expect(model.institutionsLoadFailed == true)
        #expect(model.institutions.isEmpty)
    }

    @Test func startConnectionReturnsTheAuthorizationURLAndForwardsTheLogo() async throws {
        let client = FakeAPIClient()
        await client.setStartConnectionResult(
            StartConnectionResponse(connectionID: UUID(), authorizationURL: "https://sca.example.test/go")
        )
        let model = AccountsViewModel(client: client)

        let url = await model.startConnection(
            InstitutionResponse(
                name: "TEST BANK 01", country: "IT", logo: "https://logos.example.test/tb01/"
            )
        )

        #expect(url == URL(string: "https://sca.example.test/go"))
        #expect(model.startConnectionFailed == false)
        let recorded = await client.startedConnections
        #expect(
            recorded == [
                .init(
                    institution: "TEST BANK 01", country: "IT",
                    logo: "https://logos.example.test/tb01/"
                )
            ]
        )
    }

    @Test func startConnectionOnFailureSetsStartConnectionFailedAndReturnsNil() async throws {
        let client = FakeAPIClient()
        await client.setStartConnectionError(FakeAPIError())
        let model = AccountsViewModel(client: client)

        let url = await model.startConnection(
            InstitutionResponse(name: "TEST BANK 01", country: "IT", logo: nil)
        )

        #expect(url == nil)
        #expect(model.startConnectionFailed == true)
    }

    // MARK: Manual accounts (ADR 0020)

    private static func makeManualAccount(id: UUID = UUID()) -> AccountResponse {
        makeAccount(
            id: id, connectionID: nil, source: .manual, kind: .cash,
            name: nil, alias: "Contanti", displayName: "Contanti"
        )
    }

    @Test func createManualAccountAppendsTheAccountAndBumpsSuccessTick() async throws {
        let client = FakeAPIClient()
        await client.setAccounts([Self.makeAccount()])
        let model = AccountsViewModel(client: client)
        await model.load()
        let created = Self.makeManualAccount()
        await client.setCreateManualAccountResult(created)

        let ok = await model.createManualAccount(
            alias: "Contanti", kind: .cash, currency: "EUR", color: nil, icon: nil
        )

        #expect(ok)
        #expect(model.accountActionFailure == nil)
        #expect(model.accounts.contains { $0.id == created.id })
        #expect(model.successTick == 1)
        let recorded = await client.createdManualAccounts
        #expect(recorded == [.init(alias: "Contanti", kind: .cash, currency: "EUR", color: nil, icon: nil)])
    }

    @Test func createManualAccountOn422SurfacesInvalidAlias() async throws {
        let client = FakeAPIClient()
        let model = AccountsViewModel(client: client)
        await client.setCreateManualAccountError(APIError.badStatus(422))

        let ok = await model.createManualAccount(
            alias: "   ", kind: .cash, currency: "EUR", color: nil, icon: nil
        )

        #expect(!ok)
        #expect(model.accountActionFailure == .invalidAlias)
        #expect(model.accounts.isEmpty)
    }

    @Test func deleteManualAccountRemovesItFromTheList() async throws {
        let client = FakeAPIClient()
        let manual = Self.makeManualAccount()
        await client.setAccounts([Self.makeAccount(), manual])
        let model = AccountsViewModel(client: client)
        await model.load()

        let ok = await model.deleteManualAccount(id: manual.id)

        #expect(ok)
        #expect(!model.accounts.contains { $0.id == manual.id })
        let recorded = await client.deletedAccountIDs
        #expect(recorded == [manual.id])
    }

    @Test func deleteManualAccountOn409SurfacesAccountNotEmpty() async throws {
        let client = FakeAPIClient()
        let manual = Self.makeManualAccount()
        await client.setAccounts([manual])
        let model = AccountsViewModel(client: client)
        await model.load()
        await client.setDeleteAccountError(APIError.badStatus(409))

        let ok = await model.deleteManualAccount(id: manual.id)

        #expect(!ok)
        #expect(model.accountActionFailure == .accountNotEmpty)
        #expect(model.accounts.contains { $0.id == manual.id })
    }
}
