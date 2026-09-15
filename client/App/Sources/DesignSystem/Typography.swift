import SwiftUI

/// The client's type scale — the system font, sized relative to a
/// `Font.TextStyle` rather than fixed points so Dynamic Type works without
/// per-screen extra work (ADR 0008 names this a day-one requirement, not a
/// follow-up).
///
/// `design: .rounded` since `docs/decisions/0034-brand-triad.md` — still the
/// system font (SF Pro Rounded, not a bundled typeface: zero new
/// dependencies, Dynamic Type and every existing size/weight untouched), but
/// a voice of its own instead of the same default every stock app ships
/// with. Applied to every token uniformly, figures included: a rounded
/// number next to a sharp one would read as a mistake, not a choice.
enum Typography {
    /// A card's small uppercase label ("SPESO QUESTO PERIODO").
    static let eyebrow = Font.system(.caption2, design: .rounded, weight: .bold)

    /// A card's section title.
    static let cardTitle = Font.system(.subheadline, design: .rounded, weight: .semibold)

    /// The large protagonist figure (the dashboard hero amount). Bigger than
    /// `.largeTitle` since the 2026-09-08 "dose, non tinta" revision removed
    /// the colour band behind it — the figure now carries the top of the
    /// screen on its own. `Font.system(size:)` still scales with Dynamic Type
    /// in SwiftUI (unlike UIKit), so this stays a day-one accessible size.
    static let heroFigure = Font.system(size: 44, weight: .bold, design: .rounded)

    /// A secondary stat figure (entrate/netto row).
    static let statFigure = Font.system(.title3, design: .rounded, weight: .bold)

    /// A compact figure (currency chip amount).
    static let compactFigure = Font.system(.subheadline, design: .rounded, weight: .bold)

    /// Body text.
    static let body = Font.system(.body, design: .rounded, weight: .regular)

    /// A muted caption (dates, counts, notes).
    static let caption = Font.system(.footnote, design: .rounded, weight: .regular)
}
