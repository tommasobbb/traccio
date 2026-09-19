import Foundation
import TraccioCore

extension CalendarPeriod {
    /// A display title for this period, e.g. "agosto 2026" (month), "T3 2026"
    /// (quarter), "2026" (year) — `TraccioCore.formatDate` where that can do
    /// it (month, year), and a small Italian-only literal for the quarter
    /// label ("T" for "Trimestre"), consistent with the client being
    /// officially Italian-only (`docs/engineering.md`). Lives here, not on
    /// `CalendarPeriod` itself in `TraccioCore`, per the "display copy stays
    /// in the view" rule `TransactionPeriodPreset` and
    /// `TransactionsView.title(for:)` already follow — used by both
    /// `DashboardPeriodPicker` and `DashboardStatsCard`'s comparison text.
    var displayTitle: String {
        switch unit {
        case .month:
            return TraccioCore.formatDate(start, style: .monthYear).capitalized
        case .quarter:
            let calendar = Calendar.current
            let quarter = (calendar.component(.month, from: start) - 1) / 3 + 1
            let year = calendar.component(.year, from: start)
            return "T\(quarter) \(year)"
        case .year:
            return TraccioCore.formatDate(start, style: .year)
        }
    }
}
