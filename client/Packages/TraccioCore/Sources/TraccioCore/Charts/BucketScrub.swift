import Foundation

extension TraccioCore {
    /// Map a horizontal drag position across a bar chart to the bucket it is
    /// over.
    ///
    /// `fraction` is the touch location as a fraction of the chart's own
    /// width (`0` at the leading edge, `1` at the trailing edge) — the view
    /// computes this from a `DragGesture`'s location and the chart's frame,
    /// keeping this function free of any drawing framework (no `CGFloat`/
    /// `CGRect`), same split as `fraction(forPoint:in:)`.
    ///
    /// Parameters
    /// ----------
    /// fraction:
    ///     The touch location as a fraction of the chart's width. Clamped to
    ///     `0...1` — a drag that strays outside the chart still resolves to
    ///     the nearest edge bucket rather than losing the selection.
    /// count:
    ///     How many bars the chart has.
    ///
    /// Returns
    /// -------
    /// The bucket index in `0..<count`, or `nil` when `count` is `0` (an
    /// empty chart has nothing to select).
    public static func bucketIndex(atFraction fraction: Double, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        let index = Int(clamped * Double(count))
        return min(index, count - 1)
    }
}
