import Foundation

/// The ring geometry `fraction(forPoint:in:)` hit-tests against — the same
/// two numbers `DonutChart` already draws with (`diameter`, `lineWidth`), so
/// the view passes its own drawing parameters straight through rather than
/// this type inventing a second description of the ring.
public struct DonutGeometry: Sendable, Equatable {
    public let diameter: Double
    public let lineWidth: Double

    public init(diameter: Double, lineWidth: Double) {
        self.diameter = diameter
        self.lineWidth = lineWidth
    }
}

extension TraccioCore {
    /// The fraction around the ring that `point` falls under, or `nil` if
    /// `point` lies outside the ring's stroke band.
    ///
    /// `point` is relative to the ring's own center `(0, 0)`, in the same
    /// units as `geometry` — the view converts a gesture's location into
    /// this coordinate space before calling in, so this function stays free
    /// of any drawing framework (no `CGPoint`/`CGRect`).
    ///
    /// The fraction convention matches `DonutSegment`'s: `0` at 12 o'clock,
    /// increasing clockwise, wrapping before `1`. Screen coordinates have
    /// `y` increasing downward, which is what makes a plain `atan2(x, -y)`
    /// read as clockwise from the top without any extra sign juggling.
    ///
    /// Parameters
    /// ----------
    /// point:
    ///     The tested location, relative to the ring's center.
    /// geometry:
    ///     The ring's `diameter`/`lineWidth`, defining the annulus
    ///     `[radius - lineWidth, radius]` a hit must fall within.
    ///
    /// Returns
    /// -------
    /// The fraction in `0..<1`, or `nil` when `point` is inside the ring's
    /// hole or outside its outer edge.
    public static func fraction(forPoint point: (x: Double, y: Double), in geometry: DonutGeometry) -> Double? {
        let radius = geometry.diameter / 2
        let innerRadius = radius - geometry.lineWidth
        let distance = (point.x * point.x + point.y * point.y).squareRoot()
        guard distance >= innerRadius, distance <= radius else { return nil }

        var angle = atan2(point.x, -point.y)
        if angle < 0 { angle += 2 * .pi }
        return angle / (2 * .pi)
    }

    /// The segment covering `fraction`, or `nil` if none does.
    ///
    /// `segments` is trusted to already cover `0...1` with no gaps or
    /// overlaps (`donutSegments(_:)`'s own contract) — this only walks the
    /// list, it does not validate that contract. A `fraction` that lands
    /// exactly on `1.0` (a floating-point edge from a hit at precisely 12
    /// o'clock, wrapped) resolves to the last segment rather than `nil`.
    ///
    /// Parameters
    /// ----------
    /// fraction:
    ///     A value in `0...1`, typically from `fraction(forPoint:in:)`.
    /// segments:
    ///     The donut's segments, in the order `donutSegments(_:)` returned.
    ///
    /// Returns
    /// -------
    /// The segment whose `[startFraction, endFraction)` contains `fraction`,
    /// or `nil` if `segments` is empty.
    public static func segment(atFraction fraction: Double, in segments: [DonutSegment]) -> DonutSegment? {
        if let match = segments.first(where: { fraction >= $0.startFraction && fraction < $0.endFraction }) {
            return match
        }
        return segments.last.flatMap { fraction >= $0.startFraction ? $0 : nil }
    }
}
