import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.equalSplit(total:ways:)`.
struct EqualSplitTests {
    @Test func splitsEvenlyWhenTotalDividesExactly() {
        #expect(TraccioCore.equalSplit(total: 3000, ways: 3) == [1000, 1000, 1000])
    }

    @Test func distributesTheRemainderToTheFirstShares() {
        // 1000 cents over 3 ways: 334 + 333 + 333.
        #expect(TraccioCore.equalSplit(total: 1000, ways: 3) == [334, 333, 333])
    }

    @Test func everyShareSumsBackToTheTotal() {
        let shares = TraccioCore.equalSplit(total: 12_345, ways: 7)
        #expect(shares.reduce(0, +) == 12_345)
        #expect(shares.count == 7)
    }

    @Test func returnsEmptyForZeroOrNegativeWays() {
        #expect(TraccioCore.equalSplit(total: 1000, ways: 0).isEmpty)
        #expect(TraccioCore.equalSplit(total: 1000, ways: -1).isEmpty)
    }

    @Test func singleWayReturnsTheWholeTotal() {
        #expect(TraccioCore.equalSplit(total: 1000, ways: 1) == [1000])
    }
}
