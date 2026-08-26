import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `DashboardViewModel` against `FakeAPIClient` — no network stub
/// needed, per `.claude/rules/swift.md`'s "test the seam." Fixtures are
/// synthetic (`.claude/rules/data-safety.md`).
@MainActor
struct DashboardViewModelTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_755_000_000)  // 2025-08-12

    private static func makeSummary(currency: String = "EUR") -> DashboardSummaryResponse {
        DashboardSummaryResponse(
            currencies: [
                CurrencySummaryResponse(currency: currency, spending: 5000, income: 0, net: -5000, transactionCount: 3)
            ]
        )
    }

    @Test func loadPublishesLoadedStateOnSuccess() async throws {
        let client = FakeAPIClient()
        await client.setDashboardSummaryResult(Self.makeSummary())
        let model = DashboardViewModel(client: client, period: .current(now: Self.fixedNow))

        await model.load()

        guard case .loaded(let summary) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(summary.currencies.first?.currency == "EUR")
    }

    @Test func loadPublishesFailedOnError() async throws {
        let client = FakeAPIClient()
        await client.setDashboardSummaryError(FakeAPIError())
        let model = DashboardViewModel(client: client, period: .current(now: Self.fixedNow))

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected .failed")
            return
        }
    }

    @Test func loadSendsThePeriodsStartAndEnd() async throws {
        let client = FakeAPIClient()
        let period = MonthPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)

        await model.load()

        let periods = await client.receivedDashboardSummaryPeriods
        #expect(periods.count == 1)
        #expect(periods[0].start == period.start)
        #expect(periods[0].end == period.end)
    }

    @Test func goToPreviousMonthStepsBackAndReloads() async throws {
        let client = FakeAPIClient()
        let period = MonthPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)

        await model.goToPreviousMonth()

        #expect(model.period == period.previous())
        let periods = await client.receivedDashboardSummaryPeriods
        #expect(periods.last?.start == period.previous().start)
    }

    @Test func goToNextMonthStepsForwardAndReloads() async throws {
        let client = FakeAPIClient()
        let period = MonthPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)

        await model.goToNextMonth()

        #expect(model.period == period.next())
        let periods = await client.receivedDashboardSummaryPeriods
        #expect(periods.last?.start == period.next().start)
    }

    @Test func loadResetsSelectionAndExpansion() async throws {
        let client = FakeAPIClient()
        await client.setDashboardSummaryResult(Self.makeSummary())
        let model = DashboardViewModel(client: client, period: .current(now: Self.fixedNow))
        let categoryID = UUID()
        model.selectCategory(categoryID)
        model.toggleExpanded(categoryID)
        #expect(model.selectedCategoryID == .category(categoryID))
        #expect(model.expandedRootIDs.contains(categoryID))

        await model.load()

        #expect(model.selectedCategoryID == .none)
        #expect(model.expandedRootIDs.isEmpty)
    }

    // MARK: selectCategory

    @Test func selectCategorySelectsAnUnselectedCategory() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))
        let categoryID = UUID()

        model.selectCategory(categoryID)

        #expect(model.selectedCategoryID == .category(categoryID))
    }

    @Test func selectCategoryTogglesOffTheAlreadySelectedCategory() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))
        let categoryID = UUID()
        model.selectCategory(categoryID)

        model.selectCategory(categoryID)

        #expect(model.selectedCategoryID == .none)
    }

    @Test func selectCategorySwitchesBetweenTwoDifferentCategories() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))
        let first = UUID()
        let second = UUID()
        model.selectCategory(first)

        model.selectCategory(second)

        #expect(model.selectedCategoryID == .category(second))
    }

    @Test func selectCategoryWithNilSelectsTheNoCategoryBucket() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))

        model.selectCategory(nil)

        #expect(model.selectedCategoryID == .category(nil))
        // Selecting a real category afterward must not be confused with the
        // no-category bucket already being "selected" in some looser sense.
        let categoryID = UUID()
        model.selectCategory(categoryID)
        #expect(model.selectedCategoryID == .category(categoryID))
    }

    // MARK: toggleExpanded

    @Test func toggleExpandedInsertsThenRemoves() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))
        let rootID = UUID()

        model.toggleExpanded(rootID)
        #expect(model.expandedRootIDs.contains(rootID))

        model.toggleExpanded(rootID)
        #expect(!model.expandedRootIDs.contains(rootID))
    }

    // MARK: drillThroughFilter

    @Test func drillThroughFilterScopesToACategoryAndThePeriod() {
        let period = MonthPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: FakeAPIClient(), period: period)
        let categoryID = UUID()

        let filter = model.drillThroughFilter(categoryID: categoryID)

        #expect(filter.category == .some(categoryID))
        #expect(filter.start == period.start)
        #expect(filter.end == period.end)
    }

    @Test func drillThroughFilterWithNilCategoryIsUncategorized() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))

        let filter = model.drillThroughFilter(categoryID: nil)

        #expect(filter.category == .uncategorized)
    }
}
