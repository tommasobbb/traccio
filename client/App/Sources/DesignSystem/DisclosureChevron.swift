import SwiftUI

/// The row-disclosure chevron (`chevron.right`, or `chevron.down` when a
/// row expands in place) — a fixed size, weight, and colour shared by every
/// row that pushes or expands, replacing four slightly different ad hoc
/// versions (11/12/13pt, `.semibold` or `.caption`'s regular weight,
/// `inkQuaternary` in most places but `inkTertiary` in two) found during the
/// 2026-09-15 coherence pass (`docs/decisions/0031-visual-coherence-pass.md`).
/// Chrome, not a control — `inkQuaternary`, never the accent
/// (`docs/design/tokens.md`'s "Accent dosage": "never navigation chrome").
struct DisclosureChevron: View {
    var isExpanded = false

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.inkQuaternary)
            .accessibilityHidden(true)
    }
}
