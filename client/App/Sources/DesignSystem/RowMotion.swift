import SwiftUI

extension View {
    /// The quiet scroll entrance every list row shares — a hint of opacity
    /// and scale as the row crosses into view, never a position change.
    /// Introduced by the 2026-09-15 coherence pass
    /// (`docs/decisions/0031-visual-coherence-pass.md`) for `TransactionRow`,
    /// `EventRow`, `RuleRow`, and `BreakdownRowView`. SwiftUI backs this off
    /// under Reduce Motion automatically, same as every other motion in
    /// `docs/design/tokens.md` (`AmountText`'s digit-roll,
    /// `SkeletonBlock`'s shimmer).
    func rowScrollTransition() -> some View {
        scrollTransition { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.4)
                .scaleEffect(phase.isIdentity ? 1 : 0.97)
        }
    }
}
