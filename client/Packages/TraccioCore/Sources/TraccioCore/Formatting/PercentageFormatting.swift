import Foundation

extension TraccioCore {
    /// Round a ratio to the nearest whole percentage.
    ///
    /// The one place "12.4% → 12" happens — before this, `AccountBreakdownCard`,
    /// `BreakdownRowView`, and `DashboardView`'s period-comparison text each
    /// rounded their own ratio the same way (`Int((x * 100).rounded())`). None
    /// of the three is a financial derivation (`docs/architecture.md`): the
    /// ratio itself always comes from backend-supplied figures (two spending
    /// amounts, or `spendingDeltaPct`) — this only rounds it for display, the
    /// same class of client-local arithmetic as `CategoryBreakdownRow.fillFraction`.
    ///
    /// Parameters
    /// ----------
    /// ratio:
    ///     The fraction to display as a percentage, e.g. `0.124` for "12%".
    ///     Not clamped to `0...1` — a ratio above 1 or negative rounds the
    ///     same way, since a caller (e.g. a period-over-period comparison)
    ///     may legitimately exceed 100% or go negative.
    ///
    /// Returns
    /// -------
    /// The nearest whole percentage, unsigned — a caller that needs a sign
    /// or a "%" suffix adds it.
    public static func roundedPercentage(_ ratio: Double) -> Int {
        Int((ratio * 100).rounded())
    }
}
