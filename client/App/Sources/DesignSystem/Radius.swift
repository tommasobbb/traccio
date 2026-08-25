import SwiftUI

/// The client's corner-radius tokens.
///
/// Values are recorded in `docs/design/tokens.md`'s "Radii" section — see
/// `Spacing.swift`'s doc comment for why this exists now and why it is
/// adopted only in new or rewritten views.
enum Radius {
    static let card: CGFloat = 20
    static let row: CGFloat = 16
    static let tile: CGFloat = 12
    /// Fully rounded — a pill button or chip.
    static let pill: CGFloat = 999
}
