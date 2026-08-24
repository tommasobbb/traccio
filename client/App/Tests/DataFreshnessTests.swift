import Testing

@testable import Traccio

/// Tests for `DataFreshness` itself — the scoped invalidation signal every
/// screen keys its `.task(id:)` to.
@MainActor
struct DataFreshnessTests {
    @Test func eachScopeStartsAtZero() {
        let freshness = DataFreshness()
        #expect(freshness.token(for: .dashboard) == 0)
        #expect(freshness.token(for: .transactions) == 0)
    }

    @Test func markingOneScopeStaleLeavesTheOtherUntouched() {
        let freshness = DataFreshness()

        freshness.markStale([.dashboard])

        #expect(freshness.token(for: .dashboard) == 1)
        #expect(freshness.token(for: .transactions) == 0)
    }

    @Test func markingBothScopesStaleBumpsBoth() {
        let freshness = DataFreshness()

        freshness.markStale([.dashboard, .transactions])

        #expect(freshness.token(for: .dashboard) == 1)
        #expect(freshness.token(for: .transactions) == 1)
    }

    @Test func repeatedInvalidationKeepsIncrementing() {
        let freshness = DataFreshness()

        freshness.markStale([.dashboard])
        freshness.markStale([.dashboard])
        freshness.markStale([.dashboard])

        #expect(freshness.token(for: .dashboard) == 3)
    }
}
