import Foundation

/// One arc of the dashboard's "Per categoria" donut, as produced by
/// `donutSegments(_:)`.
///
/// `startFraction`/`endFraction` are positions around the circle in `0...1`
/// (0 = the top, going clockwise), not angles — the view converts to degrees
/// or radians at draw time, keeping this type free of any drawing framework.
/// `rank` is this segment's 0-based position among the segments actually
/// drawn (biggest spender first) — no longer a color key (the rank-based
/// `Palette.categoryChart(rank:)` rotation was retired in the
/// 2026-08-26 revision of ADR 0008: `color` below carries the category's own
/// token instead), but still useful to a caller for `ForEach`'s `id` or
/// ordering text.
public struct DonutSegment: Sendable, Equatable {
    public let categoryID: UUID?
    public let startFraction: Double
    public let endFraction: Double
    public let rank: Int
    /// This segment's own category colour (`nil` on the backend response
    /// falls back to `.slate`, same default `IconTile` uses elsewhere).
    public let color: PaletteColor

    public init(
        categoryID: UUID?, startFraction: Double, endFraction: Double, rank: Int, color: PaletteColor
    ) {
        self.categoryID = categoryID
        self.startFraction = startFraction
        self.endFraction = endFraction
        self.rank = rank
        self.color = color
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
    /// One arc per category **root** (`docs/decisions/
    /// 0007-dashboard-aggregation.md`'s third revision, ADR 0018's
    /// hierarchy) — a child's spending is already rolled into its root's
    /// `spending`, so drawing children separately would double-count.
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
    public static func donutSegments(_ entries: [CategoryGroupSummaryResponse]) -> [DonutSegment] {
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
                rank: rank,
                color: entry.color ?? .slate
            )
            cursor += fraction
            return segment
        }
    }
}
