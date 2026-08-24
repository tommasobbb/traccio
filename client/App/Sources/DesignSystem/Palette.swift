import SwiftUI

/// The client's color tokens.
///
/// Values are recorded in `docs/design/tokens.md` — that file is
/// authoritative; this is its Swift form. Light-only for now (ADR 0008
/// budgets dark mode as separate, explicit follow-up work, not something a
/// custom palette gets for free the way stock components do).
///
/// A plain `enum` of static constants rather than an asset catalog: the
/// project has none today, and one light-only palette this size doesn't earn
/// the ceremony. Revisit when dark mode needs `ColorScheme`-aware values
/// (ADR 0008, "Revisit when").
enum Palette {
    // MARK: Surfaces

    static let background = Color(hex: 0xF5_F5F7)
    static let card = Color.white
    static let neutralFill = Color(hex: 0xE5_E5EA)

    // MARK: Ink

    static let ink = Color(hex: 0x1C_1C1E)
    static let inkSecondary = Color(hex: 0x6E_6E73)
    static let inkTertiary = Color(hex: 0x8E_8E93)
    static let inkQuaternary = Color(hex: 0xAE_AEB2)

    // MARK: Accent

    static let accent = Color(hex: 0x58_56D6)
    static let accentPressed = Color(hex: 0x42_3FC0)

    // MARK: Semantic

    /// Positive amounts (salary, reimbursement). Spending never uses a
    /// dedicated color — it stays `ink` — so this is the only semantic color
    /// an amount can carry besides `accent` on a positive `net`.
    static let income = Color(hex: 0x24_8A3D)
    static let incomeTint = Color(hex: 0xE2_F7E6)

    static let warning = Color(hex: 0xC2_660A)
    /// Consent-expiry banner title text — `warning` itself is too
    /// low-contrast for small bold text on `warningTint`.
    static let warningInk = Color(hex: 0x8A_4B08)
    static let warningTint = Color(hex: 0xFF_F1DE)
    static let warningBorder = Color(hex: 0xFF_D8A8)
    static let statusWarn = Color(hex: 0xFF_9500)

    /// Category iconography only — never an amount.
    static let categoryRed = Color(hex: 0xD7_0015)
    static let categoryRedTint = Color(hex: 0xFF_EDEC)

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
    static let categoryChart1 = Color(hex: 0x2A_78D6)
    static let categoryChart2 = Color(hex: 0xED_A100)
    static let categoryChart3 = Color(hex: 0xEB_6834)
    static let categoryChart4 = Color(hex: 0xE8_7BA4)
    static let categoryChart5 = Color(hex: 0x1C_93A6)

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

    static let separator = ink.opacity(0.08)
    static let separatorSubtle = ink.opacity(0.06)
    static let cardShadow = Color.black.opacity(0.16)
}

extension Color {
    /// Build a `Color` from a packed `0xRRGGBB` literal, so `Palette` can be
    /// written as the hex values in `docs/design/tokens.md` directly instead
    /// of pre-converted 0–1 components.
    fileprivate init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
