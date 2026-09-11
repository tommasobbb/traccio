import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `MealVouchersViewModel` (ADR 0029) against `FakeAPIClient`.
/// Fixtures are synthetic (`.claude/rules/data-safety.md`).
@MainActor
struct MealVouchersViewModelTests {
    @Test func loadPublishesTheCurrentValue() async {
        let client = FakeAPIClient()
        await client.setSettings(SettingsResponse(trackingStartDate: nil, mealVouchersEnabled: true))
        let model = MealVouchersViewModel(client: client)

        await model.load()

        #expect(model.isEnabled == true)
        #expect(model.loadFailed == false)
    }

    @Test func loadFailureSetsLoadFailedAndLeavesValueNil() async {
        let client = FakeAPIClient()
        await client.setSettingsError(FakeAPIError())
        let model = MealVouchersViewModel(client: client)

        await model.load()

        #expect(model.isEnabled == nil)
        #expect(model.loadFailed == true)
    }

    @Test func setEnabledUpdatesTheValueAndNotifies() async {
        let client = FakeAPIClient()
        await client.setSettings(SettingsResponse(trackingStartDate: nil, mealVouchersEnabled: false))
        var changed = 0
        let model = MealVouchersViewModel(client: client)
        model.onChanged = { changed += 1 }
        await model.load()

        await model.setEnabled(true)

        #expect(model.isEnabled == true)
        #expect(await client.setMealVouchersEnabledValues == [true])
        #expect(changed == 1)
    }

    @Test func setEnabledFalseIsAFullRevert() async {
        // Reversibility (ADR 0029): turning it off must be reachable through
        // the same call, not a separate "clear" shape.
        let client = FakeAPIClient()
        await client.setSettings(SettingsResponse(trackingStartDate: nil, mealVouchersEnabled: true))
        let model = MealVouchersViewModel(client: client)
        await model.load()

        await model.setEnabled(false)

        #expect(model.isEnabled == false)
    }

    @Test func aSetEnabledFailureSetsLoadFailedWithoutChangingTheValue() async {
        let client = FakeAPIClient()
        await client.setSettings(SettingsResponse(trackingStartDate: nil, mealVouchersEnabled: false))
        let model = MealVouchersViewModel(client: client)
        await model.load()
        await client.setSettingsError(FakeAPIError())

        await model.setEnabled(true)

        #expect(model.loadFailed == true)
        #expect(model.isEnabled == false)
    }
}
