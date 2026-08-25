import SwiftUI

/// The client's color tokens.
///
/// Values are recorded in `docs/design/tokens.md` — that file is
/// authoritative; this is its Swift form. Every token is a named color in
/// `App/Resources/Colors.xcassets`, each with an explicit dark-appearance
/// variant, so `Palette.ink` and friends resolve automatically with
/// `ColorScheme` — no `@Environment(\.colorScheme)` branching needed at call
/// sites (ADR 0008's dark-mode revision). `separator`/`separatorSubtle`/
/// `cardShadow` below stay computed (`.opacity` over an asset color or over
/// `.black`) rather than becoming assets themselves — see their doc comments.
enum Palette {
    // MARK: Surfaces

    static let background = Color("Background", bundle: .main)
    static let card = Color("Card", bundle: .main)
    static let neutralFill = Color("NeutralFill", bundle: .main)

    // MARK: Ink

    static let ink = Color("Ink", bundle: .main)
    static let inkSecondary = Color("InkSecondary", bundle: .main)
    static let inkTertiary = Color("InkTertiary", bundle: .main)
    static let inkQuaternary = Color("InkQuaternary", bundle: .main)

    // MARK: Accent

    /// Named "AccentColor" rather than "Accent" so the same asset also
    /// serves as the target's global accent color
    /// (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `Project.yml`) —
    /// one color, not two colorsets kept in sync by hand.
    static let accent = Color("AccentColor", bundle: .main)
    static let accentPressed = Color("AccentPressed", bundle: .main)

    // MARK: Semantic

    /// Positive amounts (salary, reimbursement). Spending never uses a
    /// dedicated color — it stays `ink` — so this is the only semantic color
    /// an amount can carry besides `accent` on a positive `net`.
    static let income = Color("Income", bundle: .main)
    static let incomeTint = Color("IncomeTint", bundle: .main)

    static let warning = Color("Warning", bundle: .main)
    /// Consent-expiry banner title text — `warning` itself is too
    /// low-contrast for small bold text on `warningTint`.
    static let warningInk = Color("WarningInk", bundle: .main)
    static let warningTint = Color("WarningTint", bundle: .main)
    static let warningBorder = Color("WarningBorder", bundle: .main)
    static let statusWarn = Color("StatusWarn", bundle: .main)

    /// Category iconography only — never an amount.
    static let categoryRed = Color("CategoryRed", bundle: .main)
    static let categoryRedTint = Color("CategoryRedTint", bundle: .main)

    // MARK: Category chart

    /// Rank-based colors for the dashboard's "Per categoria" donut and
    /// legend — assigned by position in the sorted `by_category` list
    /// (biggest spender first), not per-category, so a category's color can
    /// shift between periods if its rank does. Green is deliberately absent:
    /// it is reserved for `income`, and a green segment next to a green
    /// income figure would read as two different things. The fixed "no
    /// category" bucket and the donut track reuse `inkTertiary` and
    /// `neutralFill` rather than a dedicated color — see
    /// `docs/design/tokens.md`'s "Category chart" section.
    static let categoryChart1 = Color("CategoryChart1", bundle: .main)
    static let categoryChart2 = Color("CategoryChart2", bundle: .main)
    static let categoryChart3 = Color("CategoryChart3", bundle: .main)
    static let categoryChart4 = Color("CategoryChart4", bundle: .main)
    static let categoryChart5 = Color("CategoryChart5", bundle: .main)

    /// The rotation `categoryChart(rank:)` cycles through once every color
    /// has been used once (see its doc comment).
    private static let categoryChartRotation: [Color] = [
        categoryChart1, categoryChart2, categoryChart3, categoryChart4, categoryChart5,
    ]

    /// The color for the category at `rank` (0-based) in a sorted
    /// `by_category` list, cycling through `categoryChartRotation` once
    /// exhausted rather than growing the palette for a rank the design never
    /// had to solve for.
    ///
    /// - Parameter rank: 0-based position in the sorted list (0 = biggest
    ///   spender). Negative values clamp to 0.
    /// - Returns: The color to render this rank's donut segment and legend dot.
    static func categoryChart(rank: Int) -> Color {
        let index = max(0, rank) % categoryChartRotation.count
        return categoryChartRotation[index]
    }

    // MARK: Separators and shadow

    /// Derived from `ink` rather than its own asset: `ink` is near-black in
    /// light mode and near-white in dark mode, so a low-opacity overlay of it
    /// reads as a soft dark line in light mode and a soft light line in dark
    /// mode automatically — the same "hairline on the surface color" effect
    /// either way, with no separate dark value to keep in sync.
    static let separator = ink.opacity(0.08)
    static let separatorSubtle = ink.opacity(0.06)
    /// Stays pure black in both appearances rather than gaining a dark
    /// variant. A black drop shadow is naturally near-invisible on a dark
    /// card over a dark background — that is the correct dark-mode look
    /// (Apple's own dark surfaces drop the shadow the same way); `Card`'s
    /// `separatorSubtle` border, not this shadow, is what defines a card's
    /// edge in dark mode.
    static let cardShadow = Color.black.opacity(0.16)
}
