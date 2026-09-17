import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.roundedPercentage`.
struct PercentageFormattingTests {
    @Test func roundsDownBelowTheHalfwayPoint() {
        #expect(TraccioCore.roundedPercentage(0.124) == 12)
    }

    @Test func roundsUpAtTheHalfwayPointAndAbove() {
        #expect(TraccioCore.roundedPercentage(0.125) == 13)
        #expect(TraccioCore.roundedPercentage(0.999) == 100)
    }

    @Test func handlesZero() {
        #expect(TraccioCore.roundedPercentage(0) == 0)
    }

    @Test func doesNotClampAboveOneHundredPercent() {
        #expect(TraccioCore.roundedPercentage(1.5) == 150)
    }

    @Test func doesNotClampNegativeRatios() {
        #expect(TraccioCore.roundedPercentage(-0.3) == -30)
    }
}
