import TraccioCore

/// Presentation-only `reimbursed / expected` fractions for `ProgressBar` —
/// shared between `PersonDetailView`'s summary card and `AdvancesView`'s own
/// "Da ricevere" header and "Chi ti deve" rows (2026-09-19), which used to
/// each roll a private, identical `fraction(_:)`. Lives in the feature
/// folder, not `TraccioCore`, following the "display copy stays in the view"
/// precedent `CalendarPeriod+DisplayTitle.swift` already set — the client
/// never sums these figures, it only divides two the server already gave it.
///
/// A currency with nothing expected reads as fully reimbursed when nothing is
/// outstanding either (an all-settled or empty state — the bar shows full
/// rather than empty, since "0 owed" is the good outcome), else as zero.
private func reimbursementFraction(expected: Int, reimbursed: Int, outstanding: Int) -> Double {
    guard expected > 0 else { return outstanding == 0 ? 1 : 0 }
    return Double(reimbursed) / Double(expected)
}

extension PersonSummaryResponse {
    var reimbursedFraction: Double {
        reimbursementFraction(expected: expected, reimbursed: reimbursed, outstanding: outstanding)
    }
}

extension ReceivableTotalResponse {
    var reimbursedFraction: Double {
        reimbursementFraction(expected: expected, reimbursed: reimbursed, outstanding: outstanding)
    }
}
