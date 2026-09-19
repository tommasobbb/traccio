import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `DashboardViewModel` against `FakeAPIClient` — no network stub
/// needed, per `docs/engineering.md`'s "test the seam." Fixtures are
/// synthetic (`docs/engineering.md`).
@MainActor
struct DashboardViewModelTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_755_000_000)  // 2025-08-12

    /// A UTC instant, for pinning a `CalendarPeriod`'s "now" in a test.
    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? Self.fixedNow
    }

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
        let period = CalendarPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)

        await model.load()

        let requests = await client.receivedDashboardSummaryRequests
        #expect(requests.count == 1)
        #expect(requests[0].start == period.start)
        #expect(requests[0].end == period.end)
    }

    @Test func loadSendsTheGranularityMatchingThePeriodsUnit() async throws {
        let client = FakeAPIClient()
        let period = CalendarPeriod.current(unit: .quarter, now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)

        await model.load()

        let requests = await client.receivedDashboardSummaryRequests
        #expect(requests[0].granularity == .week)
    }

    @Test func loadSendsTheDevicesTimeZoneIdentifier() async throws {
        let client = FakeAPIClient()
        let model = DashboardViewModel(client: client, period: .current(now: Self.fixedNow))

        await model.load()

        let requests = await client.receivedDashboardSummaryRequests
        #expect(requests[0].tz == TimeZone.current.identifier)
    }

    @Test func loadSendsAComparisonWindowFromThePreviousPeriod() async throws {
        let client = FakeAPIClient()
        let period = CalendarPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)

        await model.load()

        let requests = await client.receivedDashboardSummaryRequests
        #expect(requests[0].compareStart == period.previous().start)
        #expect(requests[0].compareEnd == period.previous().end)
    }

    @Test func goToPreviousStepsBackAndReloads() async throws {
        let client = FakeAPIClient()
        let period = CalendarPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)

        await model.goToPrevious()

        #expect(model.period == period.previous())
        let requests = await client.receivedDashboardSummaryRequests
        #expect(requests.last?.start == period.previous().start)
    }

    @Test func goToNextStepsForwardAndReloads() async throws {
        let client = FakeAPIClient()
        // Two months before "now", so the next period is still in the past and
        // `canGoToNext` allows the step.
        let period = CalendarPeriod.current(now: Self.fixedNow).previous().previous()
        let model = DashboardViewModel(
            client: client, period: period, now: { Self.fixedNow }
        )

        await model.goToNext()

        #expect(model.period == period.next())
        let requests = await client.receivedDashboardSummaryRequests
        #expect(requests.last?.start == period.next().start)
    }

    @Test func canGoToNextIsFalseForThePeriodContainingNow() async throws {
        let model = DashboardViewModel(
            client: FakeAPIClient(),
            period: .current(now: Self.fixedNow),
            now: { Self.fixedNow }
        )

        #expect(model.canGoToNext == false)
    }

    @Test func goToNextIsANoOpWhenTheNextPeriodHasNotBegun() async throws {
        let client = FakeAPIClient()
        let period = CalendarPeriod.current(now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period, now: { Self.fixedNow })

        await model.goToNext()

        #expect(model.period == period)
        #expect(await client.receivedDashboardSummaryRequests.isEmpty)
    }

    @Test func canGoToPreviousFloorsAtTheEarliestMovementWhenNoTrackingStartIsSet() async throws {
        func modelAt(_ period: CalendarPeriod) async -> DashboardViewModel {
            let client = FakeAPIClient()
            await client.setSettings(SettingsResponse(trackingStartDate: nil, mealVouchersEnabled: false))
            await client.setTrackingStartSuggestion(
                TrackingStartSuggestionResponse(
                    suggestion: nil, constrainingAccountID: nil,
                    accounts: [
                        AccountEarliestResponse(
                            accountID: UUID(), displayName: "TEST CURRENT 01",
                            // A floor comfortably inside July, away from any
                            // month boundary, so the assertions don't hinge on
                            // the test machine's time zone.
                            earliest: CalendarDate(year: 2025, month: 7, day: 20)
                        )
                    ]
                )
            )
            let model = DashboardViewModel(client: client, period: period, now: { Self.fixedNow })
            await model.load()
            return model
        }

        // Viewing July: the previous period (June) is entirely before the
        // floor, so there is nothing to step back to.
        let julyModel = await modelAt(CalendarPeriod.current(now: Self.date(2025, 7, 15)))
        #expect(julyModel.earliestMovement == CalendarDate(year: 2025, month: 7, day: 20).date())
        #expect(julyModel.canGoToPrevious == false)

        // Viewing August: the previous period (July) still contains the floor.
        let augustModel = await modelAt(CalendarPeriod.current(now: Self.date(2025, 8, 15)))
        #expect(augustModel.canGoToPrevious == true)
    }

    @Test func canGoToPreviousIsTrueWhenNeitherFloorIsKnown() async throws {
        let model = DashboardViewModel(
            client: FakeAPIClient(),
            period: .current(now: Self.fixedNow),
            now: { Self.fixedNow }
        )

        #expect(model.canGoToPrevious == true)
    }

    // MARK: changeUnit

    @Test func changeUnitSwitchesToTheCurrentPeriodOfTheNewUnit() async throws {
        let client = FakeAPIClient()
        let model = DashboardViewModel(client: client, period: .current(unit: .month, now: Self.fixedNow))

        await model.changeUnit(.year)

        #expect(model.period.unit == .year)
        #expect(model.period == .current(unit: .year, now: Date()))
    }

    @Test func changeUnitToTheAlreadyActiveUnitIsANoOp() async throws {
        let client = FakeAPIClient()
        let period = CalendarPeriod.current(unit: .month, now: Self.fixedNow)
        let model = DashboardViewModel(client: client, period: period)
        await model.load()
        let requestCountAfterLoad = await client.receivedDashboardSummaryRequests.count

        await model.changeUnit(.month)

        #expect(model.period == period)
        let requestCountAfterNoOp = await client.receivedDashboardSummaryRequests.count
        #expect(requestCountAfterNoOp == requestCountAfterLoad)
    }

    @Test func changeUnitReloads() async throws {
        let client = FakeAPIClient()
        let model = DashboardViewModel(client: client, period: .current(unit: .month, now: Self.fixedNow))

        await model.changeUnit(.quarter)

        let requests = await client.receivedDashboardSummaryRequests
        #expect(requests.last?.granularity == .week)
    }

    @Test func loadResetsSelectionExpansionAndBucketSelection() async throws {
        let client = FakeAPIClient()
        await client.setDashboardSummaryResult(Self.makeSummary())
        let model = DashboardViewModel(client: client, period: .current(now: Self.fixedNow))
        let categoryID = UUID()
        model.selectCategory(categoryID)
        model.toggleExpanded(categoryID)
        model.selectBucket(2)
        #expect(model.selectedCategoryID == .category(categoryID))
        #expect(model.expandedRootIDs.contains(categoryID))
        #expect(model.selectedBucketIndex == 2)

        await model.load()

        #expect(model.selectedCategoryID == .none)
        #expect(model.expandedRootIDs.isEmpty)
        #expect(model.selectedBucketIndex == nil)
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

    // MARK: selectBucket

    @Test func selectBucketSetsTheIndexAndNeverToggles() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))

        model.selectBucket(3)
        #expect(model.selectedBucketIndex == 3)

        // Unlike selectCategory, selecting the same index again stays set —
        // a scrub gesture reports the same bucket on every unmoved frame.
        model.selectBucket(3)
        #expect(model.selectedBucketIndex == 3)

        model.selectBucket(nil)
        #expect(model.selectedBucketIndex == nil)
    }

    // MARK: drillThroughFilter(categoryID:)

    @Test func drillThroughFilterScopesToACategoryAndThePeriod() {
        let period = CalendarPeriod.current(now: Self.fixedNow)
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

    // MARK: drillThroughFilter(bucketStart:bucketEnd:)

    @Test func bucketDrillThroughFilterScopesToTheBucketsInterval() {
        let model = DashboardViewModel(client: FakeAPIClient(), period: .current(now: Self.fixedNow))
        let start = CalendarDate(year: 2026, month: 8, day: 10)
        let end = CalendarDate(year: 2026, month: 8, day: 11)

        let filter = model.drillThroughFilter(bucketStart: start, bucketEnd: end)

        #expect(filter != nil)
        #expect(filter?.start == start.date())
        #expect(filter?.end == end.date())
        // No category constraint — only the period narrows the result.
        #expect(filter?.category == .any)
    }
}
