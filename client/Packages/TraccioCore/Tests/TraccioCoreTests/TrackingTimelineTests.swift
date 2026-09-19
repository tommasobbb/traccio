import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.trackingTimeline(...)` — the "Inizio tracciamento"
/// axis geometry. Fixtures are synthetic (`docs/engineering.md`).
struct TrackingTimelineTests {
    private let a1 = UUID()
    private let a2 = UUID()
    private let a3 = UUID()

    private func account(
        _ id: UUID, _ name: String, earliest: CalendarDate?
    ) -> AccountEarliestResponse {
        AccountEarliestResponse(accountID: id, displayName: name, earliest: earliest)
    }

    @Test func axisRunsFromEarliestMovementToNow() {
        let suggestion = TrackingStartSuggestionResponse(
            suggestion: CalendarDate(year: 2026, month: 6, day: 1),
            constrainingAccountID: a3,
            accounts: [
                account(a1, "Revolut", earliest: CalendarDate(year: 2024, month: 3, day: 1)),
                account(a2, "Isybank", earliest: CalendarDate(year: 2024, month: 11, day: 1)),
                account(a3, "PayPal", earliest: CalendarDate(year: 2026, month: 6, day: 1)),
            ]
        )

        let timeline = TraccioCore.trackingTimeline(
            suggestion: suggestion,
            current: nil,
            now: CalendarDate(year: 2026, month: 9, day: 1)
        )

        #expect(timeline.axisStart == CalendarDate(year: 2024, month: 3, day: 1))
        #expect(timeline.axisEnd == CalendarDate(year: 2026, month: 9, day: 1))
        // Earliest account sits at the axis' left edge, latest near the right.
        #expect(timeline.bars[0].startFraction == 0)
        #expect(timeline.bars[2].startFraction ?? 0 > 0.8)
        #expect(timeline.bars[2].isConstraining)
        #expect(timeline.bars[0].isConstraining == false)
    }

    @Test func thresholdFallsBackToSuggestionWhenNoFloorIsSet() {
        let suggestion = TrackingStartSuggestionResponse(
            suggestion: CalendarDate(year: 2025, month: 1, day: 1),
            constrainingAccountID: a1,
            accounts: [account(a1, "Revolut", earliest: CalendarDate(year: 2024, month: 1, day: 1))]
        )
        let now = CalendarDate(year: 2026, month: 1, day: 1)

        let noFloor = TraccioCore.trackingTimeline(suggestion: suggestion, current: nil, now: now)
        // 2025-01 is one year into a two-year axis.
        #expect((noFloor.thresholdFraction ?? 0).isApproximately(0.5, tolerance: 0.02))

        let withFloor = TraccioCore.trackingTimeline(
            suggestion: suggestion,
            current: CalendarDate(year: 2024, month: 7, day: 1),
            now: now
        )
        #expect((withFloor.thresholdFraction ?? 0).isApproximately(0.25, tolerance: 0.03))
    }

    @Test func noDatedAccountsLeavesTheAxisAndBarsEmpty() {
        let suggestion = TrackingStartSuggestionResponse(
            suggestion: nil,
            constrainingAccountID: nil,
            accounts: [account(a1, "Contanti", earliest: nil)]
        )

        let timeline = TraccioCore.trackingTimeline(
            suggestion: suggestion,
            current: nil,
            now: CalendarDate(year: 2026, month: 9, day: 1)
        )

        #expect(timeline.axisStart == nil)
        #expect(timeline.bars.count == 1)
        #expect(timeline.bars[0].startFraction == nil)
        #expect(timeline.thresholdFraction == nil)
    }
}

private extension Double {
    func isApproximately(_ other: Double, tolerance: Double) -> Bool {
        abs(self - other) <= tolerance
    }
}
