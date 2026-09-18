import SwiftUI

/// The client's spacing tokens.
///
/// Values are recorded in `docs/design/tokens.md`'s "Spacing" section — that
/// file is authoritative; this is its Swift form. Introduced alongside the
/// account-appearance work (ADR 0017): the values already existed as bare
/// literals scattered across ~40 call sites, so this is not a speculative
/// abstraction — it names what was already the design. Adopted in new or
/// rewritten views only; converting the rest of the existing call sites is a
/// separate, tracked cleanup (`tasks/backlog.md`), not folded into this task.
enum Spacing {
    /// Screen edge padding.
    static let gutter: CGFloat = 20
    /// Gap between stacked cards.
    static let cardGap: CGFloat = 16
    /// Card internal padding.
    static let cardPadding: CGFloat = 20
    /// Padding inside a single list-style row (an account row, a category row).
    static let rowPadding: CGFloat = 9
    /// Gap between adjacent items — a leading icon and its label, two controls
    /// in a row, cells in a grid. The most common gap in the app.
    static let itemGap: CGFloat = 12
    /// A tighter gap than `itemGap` — between stacked lines in a leading text
    /// block (a title above its subtitle), or between compact controls in a
    /// dense row.
    static let tightGap: CGFloat = 8
    /// Gap between a card's own stacked content sections — `Card`'s default
    /// spacing between whatever it's handed as content.
    static let cardSectionGap: CGFloat = 14
}
