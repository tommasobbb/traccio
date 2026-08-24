import Foundation

/// One arc of the dashboard's "Per categoria" donut, as produced by
/// `donutSegments(_:)`.
///
/// `startFraction`/`endFraction` are positions around the circle in `0...1`
/// (0 = the top, going clockwise), not angles — the view converts to degrees
/// or radians at draw time, keeping this type free of any drawing framework.
/// `rank` is this segment's 0-based position among the segments actually
/// drawn (biggest spender first), and is what `Palette.categoryChart(rank:)`
/// keys its color rotation on — see `docs/design/tokens.md`'s "Category
/// chart" section.
public struct DonutSegment: Sendable, Equatable {
    public let categoryID: UUID?
    public let startFraction: Double
    public let endFraction: Double
    public let rank: Int

    public init(categoryID: UUID?, startFraction: Double, endFraction: Double, rank: Int) {
        self.categoryID = categoryID
        self.startFraction = startFraction
        self.endFraction = endFraction
        self.rank = rank
    }
}

extension TraccioCore {
    /// Turn a currency's `by_category` breakdown into drawable donut arcs.
    ///
    /// The donut represents **spending only** — a category whose entry is
    /// pure income (`spending == 0`) contributes no arc, the same way the
    /// dashboard hero card's own figure is a spending total, not a net. The
    /// total the fractions are relative to is the sum of the included
    /// entries' `spending`, which — because a currency's `byCategory` always
    /// sums to that currency's own `spending` (see
    /// `domain/dashboard.py::summarize`) — equals the currency's total
    /// spending. `entries` is expected pre-sorted (the backend already
    /// orders `by_category` by spending descending), so this function does
    /// not re-sort; it only filters and accumulates.
    ///
    /// Parameters
    /// ----------
    /// entries:
    ///     One currency's `byCategory` list, in the order the backend
    ///     returned it.
    ///
    /// Returns
    /// -------
    /// One `DonutSegment` per entry with positive spending, in the same
    /// relative order, covering `0...1` with no gaps or overlaps. Empty if
    /// no entry has any spending at all.
    public static func donutSegments(_ entries: [CategorySummaryResponse]) -> [DonutSegment] {
        let spending = entries.filter { $0.spending > 0 }
        let total = spending.reduce(0) { $0 + $1.spending }
        guard total > 0 else { return [] }

        var cursor = 0.0
        return spending.enumerated().map { rank, entry in
            let fraction = Double(entry.spending) / Double(total)
            let segment = DonutSegment(
                categoryID: entry.categoryID,
                startFraction: cursor,
                endFraction: cursor + fraction,
                rank: rank
            )
            cursor += fraction
            return segment
        }
    }
}
