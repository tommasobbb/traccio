import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.relativeTime(from:to:locale:)`. Both instants and
/// the locale are pinned so the assertion is not sensitive to the machine
/// running the test.
struct RelativeTimeTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func describesAFewMinutesAgo() {
        let fourMinutesAgo = Self.now.addingTimeInterval(-4 * 60)
        let text = TraccioCore.relativeTime(
            from: fourMinutesAgo, to: Self.now, locale: Locale(identifier: "en_US")
        )
        #expect(text.localizedCaseInsensitiveContains("minute"))
    }

    @Test func describesAnHourAgoInItalian() {
        let anHourAgo = Self.now.addingTimeInterval(-60 * 60)
        let text = TraccioCore.relativeTime(
            from: anHourAgo, to: Self.now, locale: Locale(identifier: "it_IT")
        )
        #expect(text.localizedCaseInsensitiveContains("ora"))
    }

    @Test func describesTheSameInstantAsNow() {
        let text = TraccioCore.relativeTime(
            from: Self.now, to: Self.now, locale: Locale(identifier: "en_US")
        )
        #expect(!text.isEmpty)
    }
}
