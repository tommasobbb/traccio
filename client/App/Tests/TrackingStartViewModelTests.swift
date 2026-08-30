import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `TrackingStartViewModel` (ADR 0024) against `FakeAPIClient`.
/// Fixtures are synthetic (`.claude/rules/data-safety.md`).
@MainActor
struct TrackingStartViewModelTests {
    private static func suggestion(
        _ date: CalendarDate? = CalendarDate(year: 2026, month: 7, day: 1)
    ) -> TrackingStartSuggestionResponse {
        TrackingStartSuggestionResponse(
            suggestion: date,
            constrainingAccountID: nil,
            accounts: []
        )
    }

    @Test func loadPublishesTheCurrentValueAndTheSuggestion() async {
        let client = FakeAPIClient()
        await client.setSettings(
            TrackingStartResponse(trackingStartDate: CalendarDate(year: 2026, month: 6, day: 1))
        )
        await client.setTrackingStartSuggestion(Self.suggestion())
        let model = TrackingStartViewModel(client: client)

        await model.load()

        guard case .loaded(let current, let suggestion) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(current == CalendarDate(year: 2026, month: 6, day: 1))
        #expect(suggestion.suggestion == CalendarDate(year: 2026, month: 7, day: 1))
    }

    @Test func loadFailureIsSurfaced() async {
        let client = FakeAPIClient()
        await client.setSettingsError(FakeAPIError())
        let model = TrackingStartViewModel(client: client)

        await model.load()

        #expect(model.state == .failed)
    }

    @Test func saveForwardsTheDateUpdatesCurrentAndNotifies() async {
        let client = FakeAPIClient()
        await client.setSettings(TrackingStartResponse(trackingStartDate: nil))
        await client.setTrackingStartSuggestion(Self.suggestion())
        var changed = 0
        let model = TrackingStartViewModel(client: client, onChanged: { changed += 1 })
        await model.load()

        let newDate = CalendarDate(year: 2026, month: 7, day: 1)
        await model.save(newDate)

        #expect(await client.setTrackingStartValues == [newDate])
        #expect(changed == 1)
        guard case .loaded(let current, _) = model.state else {
            Issue.record("expected .loaded after save")
            return
        }
        #expect(current == newDate)
    }

    @Test func saveNilClearsTheFloor() async {
        let client = FakeAPIClient()
        await client.setSettings(
            TrackingStartResponse(trackingStartDate: CalendarDate(year: 2026, month: 6, day: 1))
        )
        await client.setTrackingStartSuggestion(Self.suggestion())
        let model = TrackingStartViewModel(client: client)
        await model.load()

        await model.save(nil)

        #expect(await client.setTrackingStartValues == [CalendarDate?.none])
        guard case .loaded(let current, _) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(current == nil)
    }

    @Test func aSaveFailureSetsSaveFailedWithoutChangingCurrent() async {
        let client = FakeAPIClient()
        let existing = CalendarDate(year: 2026, month: 6, day: 1)
        await client.setSettings(TrackingStartResponse(trackingStartDate: existing))
        await client.setTrackingStartSuggestion(Self.suggestion())
        let model = TrackingStartViewModel(client: client)
        await model.load()
        await client.setSettingsError(FakeAPIError())

        await model.save(CalendarDate(year: 2026, month: 7, day: 1))

        #expect(model.saveFailed)
        guard case .loaded(let current, _) = model.state else {
            Issue.record("expected .loaded")
            return
        }
        #expect(current == existing)
    }
}
