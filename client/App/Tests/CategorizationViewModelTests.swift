import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `CategorizationViewModel` against `FakeAPIClient` — no network
/// stub needed, per `docs/engineering.md`'s "test the seam." Fixtures are
/// synthetic (`docs/engineering.md`): invented ids, round amounts,
/// `"TEST MERCHANT 01"`.
@MainActor
struct CategorizationViewModelTests {
    private static let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let ruleID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private static func makeCategory(
        id: UUID = categoryID, name: String = "Alimentari", parentID: UUID? = nil,
        color: PaletteColor = .slate
    ) -> CategoryResponse {
        CategoryResponse(
            id: id, name: name, parentID: parentID, color: color, icon: nil,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
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

    @Test func createRuleRefetchesRatherThanOrderingLocally() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule(pattern: "TEST MERCHANT 01")])
        await client.setCategories([Self.makeCategory()])
        let model = CategorizationViewModel(client: client)
        await model.load()

        // The rule the fake will return from `createRule`, plus what `load()`
        // is reconfigured to answer the *second* time it is called — proof
        // that the new order comes from a refetch, not a local insert.
        let newRuleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        await client.setCreateRuleResult(
            Self.makeRule(id: newRuleID, pattern: "TEST MERCHANT 01 SUBSCRIPTION")
        )
        await client.setRules([
            Self.makeRule(id: newRuleID, pattern: "TEST MERCHANT 01 SUBSCRIPTION"),
            Self.makeRule(pattern: "TEST MERCHANT 01"),
        ])

        await model.createRule(categoryID: Self.categoryID, matchKind: .contains, pattern: "TEST MERCHANT 01 SUBSCRIPTION")

        #expect(await client.rulesFetchCount == 2)
        guard case .loaded(let data) = model.state else {
            Issue.record("expected .loaded after createRule()")
            return
        }
        #expect(data.rules.map(\.id) == [newRuleID, Self.ruleID])
        #expect(model.actionFailure == nil)
    }

    @Test func createRuleSurfacesDuplicateFailureAndLeavesTheListUntouched() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule()])
        await client.setCategories([Self.makeCategory()])
        await client.setCreateRuleError(APIError.badStatus(409))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.createRule(categoryID: Self.categoryID, matchKind: .contains, pattern: "TEST MERCHANT 01")

        #expect(model.actionFailure == .duplicateRule)
        guard case .loaded(let data) = model.state else {
            Issue.record("expected .loaded to survive a failed createRule()")
            return
        }
        #expect(data.rules.count == 1)
    }

    @Test func createRuleSurfacesInvalidPatternFailure() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setCreateRuleError(APIError.badStatus(422))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.createRule(categoryID: Self.categoryID, matchKind: .contains, pattern: "")

        #expect(model.actionFailure == .invalidPattern)
    }

    @Test func deleteRuleRemovesItAfterRefetch() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule()])
        await client.setCategories([Self.makeCategory()])
        let model = CategorizationViewModel(client: client)
        await model.load()

        await client.setRules([])
        await model.deleteRule(id: Self.ruleID)

        #expect(await client.deletedRuleIDs == [Self.ruleID])
        guard case .loaded(let data) = model.state else {
            Issue.record("expected .loaded after deleteRule()")
            return
        }
        #expect(data.rules.isEmpty)
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

    @Test func createCategoryWithAParentPassesItThrough() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        let root = Self.makeCategory(name: "Casa")
        await client.setCategories([root])
        await client.setCreateCategoryResult(
            Self.makeCategory(id: UUID(), name: "Affitto", parentID: root.id, color: .indigo)
        )
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.createCategory(name: "Affitto", parentID: root.id, color: .indigo, icon: .rent)

        #expect(model.actionFailure == nil)
        let recorded = await client.createCategoryRequests
        #expect(
            recorded == [
                FakeAPIClient.RecordedCategoryCreate(
                    name: "Affitto", parentID: root.id, color: .indigo, icon: .rent
                )
            ]
        )
    }

    @Test func setCategoryAppearanceRefetchesOnSuccess() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setCategoryAppearanceResult(Self.makeCategory(color: .teal))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.setCategoryAppearance(id: Self.categoryID, color: .teal, icon: nil)

        #expect(model.actionFailure == nil)
        let recorded = await client.categoryAppearanceUpdates
        #expect(
            recorded == [
                FakeAPIClient.RecordedCategoryAppearance(id: Self.categoryID, color: .teal, icon: nil)
            ]
        )
    }

    @Test func setCategoryAppearanceFailureSurfacesGeneric() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setCategoryAppearanceError(APIError.badStatus(404))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.setCategoryAppearance(id: Self.categoryID, color: .teal, icon: nil)

        #expect(model.actionFailure == .generic)
    }

    @Test func applyRulesPublishesTheCounts() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule()])
        await client.setCategories([Self.makeCategory()])
        await client.setApplyRulesResult(ApplyRulesResponse(rulesApplied: 4, matched: 128, cleared: 401))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.applyRules()

        #expect(model.lastApplyResult == ApplyRulesResponse(rulesApplied: 4, matched: 128, cleared: 401))
        #expect(model.actionFailure == nil)
    }

    @Test func applyRulesNotifiesSuggestionsChanged() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule()])
        await client.setCategories([Self.makeCategory()])
        var notified = 0
        let model = CategorizationViewModel(client: client, onSuggestionsChanged: { notified += 1 })
        await model.load()

        await model.applyRules()

        #expect(notified == 1)
        #expect(await client.applyRulesCallCount == 1)
    }

    @Test func applyRulesFailureLeavesTheLastResultUntouchedAndNeverNotifies() async throws {
        let client = FakeAPIClient()
        await client.setRules([Self.makeRule()])
        await client.setCategories([Self.makeCategory()])
        await client.setApplyRulesResult(ApplyRulesResponse(rulesApplied: 1, matched: 1, cleared: 0))
        var notified = 0
        let model = CategorizationViewModel(client: client, onSuggestionsChanged: { notified += 1 })
        await model.load()
        await model.applyRules()
        #expect(model.lastApplyResult?.matched == 1)

        await client.setApplyRulesError(APIError.badStatus(500))
        await model.applyRules()

        #expect(model.actionFailure == .generic)
        #expect(model.lastApplyResult?.matched == 1)
        #expect(notified == 1)
    }

    // MARK: updateCategory

    @Test func updateCategoryIssuesBothWritesAndReloadsOnce() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        let original = Self.makeCategory(name: "Alimentari", color: .slate)
        await client.setCategories([original])
        await client.setRenameCategoryResult(Self.makeCategory(name: "Spesa", color: .slate))
        await client.setCategoryAppearanceResult(Self.makeCategory(name: "Spesa", color: .green))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await client.setCategories([Self.makeCategory(name: "Spesa", color: .green)])
        await model.updateCategory(original, name: "Spesa", color: .green, icon: nil)

        #expect(model.actionFailure == nil)
        #expect(
            await client.renamedCategories == [
                FakeAPIClient.RecordedRename(id: Self.categoryID, name: "Spesa")
            ]
        )
        #expect(
            await client.categoryAppearanceUpdates == [
                FakeAPIClient.RecordedCategoryAppearance(id: Self.categoryID, color: .green, icon: nil)
            ]
        )
        #expect(await client.categoriesFetchCount == 2)
    }

    @Test func updateCategorySkipsRenameWhenNameUnchanged() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        let original = Self.makeCategory(name: "Alimentari", color: .slate)
        await client.setCategories([original])
        await client.setCategoryAppearanceResult(Self.makeCategory(name: "Alimentari", color: .green))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.updateCategory(original, name: "Alimentari", color: .green, icon: nil)

        #expect(await client.renamedCategories.isEmpty)
        #expect(await client.categoryAppearanceUpdates.count == 1)
    }

    @Test func updateCategorySkipsAppearanceWhenUnchanged() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        let original = Self.makeCategory(name: "Alimentari", color: .slate)
        await client.setCategories([original])
        await client.setRenameCategoryResult(Self.makeCategory(name: "Spesa", color: .slate))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.updateCategory(original, name: "Spesa", color: .slate, icon: original.icon)

        #expect(await client.categoryAppearanceUpdates.isEmpty)
        #expect(await client.renamedCategories.count == 1)
    }

    @Test func updateCategoryStopsAtRenameFailureAndLeavesAppearanceUntouched() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        let original = Self.makeCategory(name: "Alimentari", color: .slate)
        await client.setCategories([original])
        await client.setRenameCategoryError(APIError.badStatus(409))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.updateCategory(original, name: "Spesa", color: .green, icon: nil)

        #expect(model.actionFailure == .nameTaken)
        #expect(await client.categoryAppearanceUpdates.isEmpty)
    }

    // MARK: moveCategory

    @Test func moveCategoryCallsMoveAndNotifiesFreshness() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        let root = Self.makeCategory(name: "Casa")
        let child = Self.makeCategory(id: UUID(), name: "Affitto", parentID: root.id)
        let otherRoot = Self.makeCategory(id: UUID(), name: "Trasporti")
        await client.setCategories([root, child, otherRoot])
        await client.setMoveCategoryResult(
            Self.makeCategory(id: child.id, name: "Affitto", parentID: otherRoot.id)
        )
        var notified = 0
        let model = CategorizationViewModel(client: client, onSuggestionsChanged: { notified += 1 })
        await model.load()

        await model.moveCategory(id: child.id, parentID: otherRoot.id)

        #expect(
            await client.movedCategories == [
                FakeAPIClient.RecordedCategoryMove(id: child.id, parentID: otherRoot.id)
            ]
        )
        #expect(notified == 1)
        #expect(model.actionFailure == nil)
    }

    @Test func moveCategoryToRootSendsNilParent() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        let root = Self.makeCategory(name: "Casa")
        let child = Self.makeCategory(id: UUID(), name: "Affitto", parentID: root.id)
        await client.setCategories([root, child])
        await client.setMoveCategoryResult(Self.makeCategory(id: child.id, name: "Affitto"))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.moveCategory(id: child.id, parentID: nil)

        #expect(
            await client.movedCategories == [
                FakeAPIClient.RecordedCategoryMove(id: child.id, parentID: nil)
            ]
        )
    }

    @Test func moveCategoryMaps409ToCategoryHasChildren() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setMoveCategoryError(APIError.badStatus(409))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.moveCategory(id: Self.categoryID, parentID: UUID())

        #expect(model.actionFailure == .categoryHasChildren)
    }

    @Test func moveCategoryMaps422ToInvalidMove() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setMoveCategoryError(APIError.badStatus(422))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.moveCategory(id: Self.categoryID, parentID: UUID())

        #expect(model.actionFailure == .invalidMove)
    }

    // MARK: updateRule

    @Test func updateRuleDeletesBeforeCreatingSoAnUnchangedPatternDoesNotConflict() async throws {
        let client = FakeAPIClient()
        let original = Self.makeRule(pattern: "TEST MERCHANT 01")
        await client.setRules([original])
        await client.setCategories([Self.makeCategory()])
        let newCategoryID = UUID()
        await client.setCreateRuleResult(Self.makeRule(id: UUID(), pattern: "TEST MERCHANT 01"))
        let model = CategorizationViewModel(client: client)
        await model.load()

        // Same (matchKind, pattern) as the original, only the category
        // changes — the case create-first would `409` on, since the
        // backend's duplicate check ignores the category.
        await client.setRules([Self.makeRule(id: Self.ruleID, pattern: "TEST MERCHANT 01")])
        await model.updateRule(
            original, categoryID: newCategoryID, matchKind: .contains, pattern: "TEST MERCHANT 01"
        )

        #expect(await client.ruleCallLog == ["delete", "create"])
        #expect(await client.deletedRuleIDs == [Self.ruleID])
        let recorded = await client.createdRuleRequests
        #expect(recorded.count == 1)
        #expect(recorded[0].categoryID == newCategoryID)
        #expect(recorded[0].matchKind == .contains)
        #expect(recorded[0].pattern == "TEST MERCHANT 01")
        #expect(model.actionFailure == nil)
    }

    @Test func updateRuleRecreatesOriginalWhenCreateFails() async throws {
        let client = FakeAPIClient()
        let original = Self.makeRule(pattern: "TEST MERCHANT 01")
        await client.setRules([original])
        await client.setCategories([Self.makeCategory()])
        await client.setCreateRuleError(APIError.badStatus(409))
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.updateRule(
            original, categoryID: Self.categoryID, matchKind: .contains,
            pattern: "TEST MERCHANT 01 SUBSCRIPTION"
        )

        // Both the real create and the compensating recreate fail (the fake's
        // error is sticky), so neither lands in `createdRuleRequests` — that
        // array only records a *successful* call. `ruleCallLog` is what
        // proves both were attempted, in order.
        #expect(await client.ruleCallLog == ["delete", "create", "create"])
        #expect(await client.deletedRuleIDs == [Self.ruleID])
        #expect(model.actionFailure == .duplicateRule)
    }

    @Test func updateRuleIsNoOpWhenNothingChanged() async throws {
        let client = FakeAPIClient()
        let original = Self.makeRule(pattern: "TEST MERCHANT 01")
        await client.setRules([original])
        await client.setCategories([Self.makeCategory()])
        let model = CategorizationViewModel(client: client)
        await model.load()

        await model.updateRule(
            original, categoryID: original.categoryID, matchKind: original.matchKind,
            pattern: original.pattern
        )

        #expect(await client.ruleCallLog.isEmpty)
        #expect(await client.rulesFetchCount == 1)
    }

    @Test func aSecondWriteWhileUpdatingIsIgnored() async throws {
        let client = FakeAPIClient()
        await client.setRules([])
        await client.setCategories([Self.makeCategory()])
        await client.setCreateCategoryResult(Self.makeCategory(name: "Trasporti"))
        let model = CategorizationViewModel(client: client)
        await model.load()

        async let first: Void = model.createCategory(
            name: "Trasporti", parentID: nil, color: .slate, icon: nil
        )
        async let second: Void = model.createCategory(
            name: "Svago", parentID: nil, color: .slate, icon: nil
        )
        _ = await (first, second)

        #expect(await client.createdCategoryNames.count == 1)
    }
}
