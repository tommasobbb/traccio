import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.bucketIndex(atFraction:count:)` — pure drag-to-index
/// mapping for the trend chart's scrub gesture.
struct BucketScrubTests {
    @Test func leadingEdgeResolvesToTheFirstBucket() {
        #expect(TraccioCore.bucketIndex(atFraction: 0, count: 5) == 0)
    }

    @Test func trailingEdgeResolvesToTheLastBucketNotOutOfBounds() {
        // fraction == 1 would naively compute index 5 for a 5-bucket chart —
        // must clamp to 4, the last valid index.
        #expect(TraccioCore.bucketIndex(atFraction: 1, count: 5) == 4)
    }

    @Test func midpointResolvesToTheMiddleBucket() {
        #expect(TraccioCore.bucketIndex(atFraction: 0.5, count: 4) == 2)
    }

    @Test func aFractionBelowZeroClampsToTheFirstBucket() {
        #expect(TraccioCore.bucketIndex(atFraction: -0.3, count: 5) == 0)
    }

    @Test func aFractionAboveOneClampsToTheLastBucket() {
        #expect(TraccioCore.bucketIndex(atFraction: 1.4, count: 5) == 4)
    }

    @Test func zeroBucketsResolvesToNil() {
        #expect(TraccioCore.bucketIndex(atFraction: 0.5, count: 0) == nil)
    }

    @Test func aSingleBucketAlwaysResolvesToIndexZero() {
        #expect(TraccioCore.bucketIndex(atFraction: 0, count: 1) == 0)
        #expect(TraccioCore.bucketIndex(atFraction: 0.9, count: 1) == 0)
        #expect(TraccioCore.bucketIndex(atFraction: 1, count: 1) == 0)
    }

    @Test func twelveBucketsCoverTheWholeRangeWithNoGapsOrRepeats() {
        // A year view should walk through all 12 month bars evenly.
        let indices = stride(from: 0.0, through: 1.0, by: 1.0 / 24).compactMap {
            TraccioCore.bucketIndex(atFraction: $0, count: 12)
        }
        #expect(Set(indices) == Set(0..<12))
    }
}
