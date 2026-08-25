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
        name: String? = "TEST CURRENT 01",
        alias: String? = nil,
        displayName: String? = "TEST CURRENT 01",
        color: PaletteColor? = nil,
        icon: AccountIcon? = nil
    ) -> AccountResponse {
        AccountResponse(
            id: id,
            connectionID: UUID(),
            kind: .current,
            currency: "EUR",
            name: name,
            alias: alias,
            displayName: displayName,
            color: color,
            icon: icon,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
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
}
