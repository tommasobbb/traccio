import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.fraction(forPoint:in:)` and `segment(atFraction:in:)`
/// — pure geometry backing the donut's tap-to-select gesture, no drawing
/// framework or `CGPoint` involved.
struct DonutHitTestTests {
    private static let geometry = DonutGeometry(diameter: 100, lineWidth: 14)

    @Test func twelveOClockIsFractionZero() {
        // Straight up from center, on the ring (radius 43, inside [36, 50]).
        let fraction = TraccioCore.fraction(forPoint: (x: 0, y: -43), in: Self.geometry)
        #expect(fraction == 0)
    }

    @Test func threeOClockIsAQuarter() {
        let fraction = TraccioCore.fraction(forPoint: (x: 43, y: 0), in: Self.geometry)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.25) < 0.0001)
    }

    @Test func sixOClockIsAHalf() {
        let fraction = TraccioCore.fraction(forPoint: (x: 0, y: 43), in: Self.geometry)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.5) < 0.0001)
    }

    @Test func nineOClockIsThreeQuarters() {
        let fraction = TraccioCore.fraction(forPoint: (x: -43, y: 0), in: Self.geometry)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.75) < 0.0001)
    }

    @Test func movesClockwiseNotCounterclockwise() {
        // A point a few degrees clockwise of 12 o'clock (slightly toward 3
        // o'clock, i.e. positive x) must have a small positive fraction, not
        // a fraction near 1 (which would mean the mapping went the wrong way).
        let fraction = TraccioCore.fraction(forPoint: (x: 5, y: -42.7), in: Self.geometry)
        #expect(fraction != nil)
        #expect(fraction! > 0)
        #expect(fraction! < 0.1)
    }

    @Test func insideTheHoleIsNil() {
        // Radius 10 is well inside the inner radius (36).
        let fraction = TraccioCore.fraction(forPoint: (x: 0, y: -10), in: Self.geometry)
        #expect(fraction == nil)
    }

    @Test func outsideTheOuterEdgeIsNil() {
        // Radius 60 is well outside the outer radius (50).
        let fraction = TraccioCore.fraction(forPoint: (x: 0, y: -60), in: Self.geometry)
        #expect(fraction == nil)
    }

    @Test func exactlyOnTheInnerAndOuterEdgesIsIncluded() {
        #expect(TraccioCore.fraction(forPoint: (x: 0, y: -36), in: Self.geometry) != nil)
        #expect(TraccioCore.fraction(forPoint: (x: 0, y: -50), in: Self.geometry) != nil)
    }

    // MARK: segment(atFraction:in:)

    private static let segments: [DonutSegment] = [
        DonutSegment(categoryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"), startFraction: 0, endFraction: 0.5, rank: 0, color: .blue),
        DonutSegment(categoryID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"), startFraction: 0.5, endFraction: 1.0, rank: 1, color: .green),
    ]

    @Test func segmentAtFractionResolvesTheContainingSegment() {
        #expect(TraccioCore.segment(atFraction: 0.1, in: Self.segments)?.rank == 0)
        #expect(TraccioCore.segment(atFraction: 0.5, in: Self.segments)?.rank == 1)
        #expect(TraccioCore.segment(atFraction: 0.9, in: Self.segments)?.rank == 1)
    }

    @Test func segmentAtFractionOneResolvesTheLastSegment() {
        // A fraction that wrapped to exactly 1.0 (a floating-point edge)
        // belongs to the last segment, not nowhere.
        #expect(TraccioCore.segment(atFraction: 1.0, in: Self.segments)?.rank == 1)
    }

    @Test func segmentAtFractionReturnsNilForEmptySegments() {
        #expect(TraccioCore.segment(atFraction: 0.5, in: []) == nil)
    }
}
