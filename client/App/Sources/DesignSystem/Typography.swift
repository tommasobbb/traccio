import SwiftUI

/// The client's type scale — the system font (SF Pro), sized relative to a
/// `Font.TextStyle` rather than fixed points so Dynamic Type works without
/// per-screen extra work (ADR 0008 names this a day-one requirement, not a
/// follow-up).
enum Typography {
    /// A card's small uppercase label ("SPESO QUESTO PERIODO").
    static let eyebrow = Font.system(.caption2, design: .default, weight: .bold)

    /// A card's section title.
    static let cardTitle = Font.system(.subheadline, design: .default, weight: .semibold)

    /// The large protagonist figure (e.g. the dashboard hero amount).
    static let heroFigure = Font.system(.largeTitle, design: .default, weight: .bold)

    /// A secondary stat figure (entrate/netto row).
    static let statFigure = Font.system(.title3, design: .default, weight: .bold)

    /// A compact figure (currency chip amount).
    static let compactFigure = Font.system(.subheadline, design: .default, weight: .bold)

    /// Body text.
    static let body = Font.system(.body, design: .default, weight: .regular)

    /// A muted caption (dates, counts, notes).
    static let caption = Font.system(.footnote, design: .default, weight: .regular)
}
