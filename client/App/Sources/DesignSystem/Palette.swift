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
    /// A barely-there step up from `background` — carries no hue of its own.
    /// Only ever used through `backgroundGradient`
    /// (`View.screenBackground()`, `ScreenBackground.swift`), never alone:
    /// it exists so the chrome's Liquid Glass
    /// (`docs/decisions/0030-liquid-glass-chrome.md`) has something neutral
    /// to refract, not to give the screen its own tint.
    static let backgroundElevated = Color("BackgroundElevated", bundle: .main)

    /// The screen background: a vertical gradient from `background` to
    /// `backgroundElevated`. Not a reprise of the accent-band rejections
    /// above ("Accent dosage") — it carries no hue, only a luminosity step.
    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [background, backgroundElevated], startPoint: .top, endPoint: .bottom)
    }

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
    /// A pale wash of the accent, for a resting surface that should still read
    /// as "brand" — an active filter token. Not a section title or an eyebrow:
    /// see `docs/design/tokens.md`'s "Accent dosage" — the accent marks what
    /// you touch, never a filled surface or a heading.
    static let accentTint = Color("AccentTint", bundle: .main)

    // MARK: Brand triad

    /// The three identity colours (`docs/decisions/0034-brand-triad.md`),
    /// deliberately separate from `accent` — they mark a *brand/structural*
    /// surface (a screen's protagonist card, a header, chrome), never a data
    /// row or a money figure, which stay `ink`/the semantic colours below.
    /// `accent` is untouched and keeps doing what it always did (buttons,
    /// links, the system's own global accent) — this is additive, not a
    /// replacement.
    ///
    /// `brandNight` is near-black navy in both appearances by design (a
    /// brand surface, not a system-adaptive neutral) — the dark variant is
    /// lifted a few points so it still shows an edge against the dark
    /// `Background` (`#0B0B0C`), same reasoning as `Background`'s own light
    /// lift off pure black. `brandLime` and `brandCream` are pulled back a
    /// little in dark mode so a colour this saturated doesn't glow against
    /// an OLED-dark surface — the same adjustment the app icon's dark
    /// variant already makes for its own gradient. All three are a judgment
    /// call pending the on-device pass (`tasks/backlog.md` item 13).
    static let brandNight = Color("BrandNight", bundle: .main)
    /// The one colour that reads as "you can touch this" on a `brandNight`
    /// surface — a CTA, a selection, the hero's own key figure. Never used
    /// on a light surface: `#C8F000` on near-white has too little contrast
    /// to read as a control there, so `accent` still owns that role
    /// everywhere except inside a `brandNight` surface.
    static let brandLime = Color("BrandLime", bundle: .main)
    /// The quiet warm fill — tiles, empty states — that keeps the triad from
    /// reading as two colours plus black.
    static let brandCream = Color("BrandCream", bundle: .main)

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

    // MARK: Separators and shadow

    /// Derived from `ink` rather than its own asset: `ink` is near-black in
    /// light mode and near-white in dark mode, so a low-opacity overlay of it
    /// reads as a soft dark line in light mode and a soft light line in dark
    /// mode automatically — the same "hairline on the surface color" effect
    /// either way, with no separate dark value to keep in sync.
    static let separator = ink.opacity(0.08)
    static let separatorSubtle = ink.opacity(0.06)
    /// Pure, fully-opaque black; the call site applies the opacity
    /// (`docs/design/tokens.md`: `.04` near, `.22` far). It previously
    /// carried its own `.opacity(0.16)`, which the `Card` modifiers then
    /// multiplied again — the far shadow rendered at ~1/14 of its documented
    /// strength, so cards dissolved into the background. Stays black in both
    /// appearances: a black drop shadow is naturally near-invisible on a dark
    /// card over a dark background, which is the correct dark-mode look
    /// (Apple's own dark surfaces drop the shadow the same way); `Card`'s
    /// `separatorSubtle` border, not this shadow, defines a card's edge in
    /// dark mode.
    static let cardShadow = Color.black
}
