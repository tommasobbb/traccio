import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `CategorizationViewModel` against `FakeAPIClient` — no network
/// stub needed, per `.claude/rules/swift.md`'s "test the seam." Fixtures are
/// synthetic (`.claude/rules/data-safety.md`): invented ids, round amounts,
/// `"TEST MERCHANT 01"`.
@MainActor
struct CategorizationViewModelTests {
    private static let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let ruleID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private static func makeCategory(id: UUID = categoryID, name: String = "Alimentari") -> CategoryResponse {
        CategoryResponse(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_755_000_000))
    }

    private static func makeRule(
        id: UUID = ruleID, pattern: String = "TEST MERCHANT 01"
    ) -> RuleResponse {
        RuleResponse(
            id: id, categoryID: categoryID, matchKind: .contains, pattern: pattern,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    @Test func loadPublishesRulesInServerOrderAndCategories() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule()])
        await client.setCategories([Self.makeCategory()])
        let model = CategorizationViewModel(client: client)

        await model.load()

        guard case .loaded(let data) = model.state else {
            Issue.record("expected .loaded after load()")
            return
        }
        #expect(data.rules.map(\.id) == [Self.ruleID])
        #expect(data.categories.map(\.id) == [Self.categoryID])
    }

    @Test func loadFailsWhenRulesFetchFails() async throws {
        let client = FakeAPIClient()
        await client.setRulesError(FakeAPIError())
        await client.setCategories([Self.makeCategory()])
        let model = CategorizationViewModel(client: client)

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected .failed after a rules-fetch failure")
            return
        }
    }

    @Test func loadFailsWhenCategoriesFetchFails() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule()])
        await client.setCategoriesError(FakeAPIError())
        let model = CategorizationViewModel(client: client)

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected .failed after a categories-fetch failure — categories are not best-effort here")
            return
        }
    }

    @Test func deleteCategorySurfacesInUseRefusalAndKeepsTheCategory() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setDeleteCategoryError(APIError.badStatus(409))
        var notified = 0
        let model = CategorizationViewModel(client: client, onSuggestionsChanged: { notified += 1 })
        await model.load()

        await model.deleteCategory(id: Self.categoryID)

        #expect(model.actionFailure == .categoryInUse(categoryID: Self.categoryID))
        #expect(notified == 0)
        guard case .loaded(let data) = model.state else {
            Issue.record("expected .loaded to survive a refused deleteCategory()")
            return
        }
        #expect(data.categories.map(\.id) == [Self.categoryID])
    }

    @Test func deleteCategoryNotifiesSuggestionsChanged() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        var notified = 0
        let model = CategorizationViewModel(client: client, onSuggestionsChanged: { notified += 1 })
        await model.load()

        await client.setCategories([])
        await model.deleteCategory(id: Self.categoryID)

        #expect(notified == 1)
        #expect(model.actionFailure == nil)
    }

    @Test func renameCategorySurfacesNameTakenFailure() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setRenameCategoryError(APIError.badStatus(409))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.renameCategory(id: Self.categoryID, name: "Spesa")

        #expect(model.actionFailure == .nameTaken)
    }

    @Test func aSecondWriteWhileUpdatingIsIgnored() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setCreateCategoryResult(Self.makeCategory(name: "Trasporti"))
        let model = CategorizationViewModel(client: client)
        await model.load()

        async let first: Void = model.createCategory(name: "Trasporti")
        async let second: Void = model.createCategory(name: "Svago")
        _ = await (first, second)

        #expect(await client.createdCategoryNames.count == 1)
    }
}
