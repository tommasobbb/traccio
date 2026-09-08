import SwiftUI
import TraccioCore

/// Renders a money amount with the spend/income color convention baked in,
/// so no screen can color a spend red (or an income figure the wrong way)
/// by accident — the single place that decision is made.
///
/// Always uses tabular (monospaced) figures, per `docs/design/tokens.md`,
/// so columns of amounts align. The fractional part (the ",dd" cents) is a
/// separate run: it can take a smaller `fractionFont` and a receded colour so
/// the whole units read first — the "designed figure" treatment from ADR
/// 0008's 2026-09-08 tone revision. The split is display-only; VoiceOver still
/// reads the whole formatted figure.
struct AmountText: View {
    /// How this amount should be colored and signed.
    enum Kind: Equatable {
        /// A spending figure. Stays in ink — **never red** — per
        /// `docs/design/tokens.md`.
        case spending
        /// An income figure: green, with an explicit "+".
        case income
        /// The one genuinely signed figure (`income - spending`). Carries the
        /// accent color when positive; ink otherwise.
        case net
        /// A transaction whose `effective_amount` is zero (a transfer leg, a
        /// reimbursement) — the bank's raw amount is still shown, but muted,
        /// per `docs/design/tokens.md`'s "non-counted amounts" ink tone. Never
        /// used for a spending or income figure.
        case notCounted
    }

    /// Where the amount is rendered, which can override its `Kind` colour.
    enum Tone {
        /// The `Kind`'s own colour convention (the default everywhere).
        case standard
        /// On the dashboard hero's forest-green band: always `Palette.onHero`
        /// (white), since ink or accent would not read on the band.
        case onHero
    }

    let amount: Int
    let currencyCode: String
    let kind: Kind
    var font: Font = Typography.statFigure
    /// Font for the ",dd" cents. Defaults to `font`; pass a smaller token to
    /// make the whole-units part the protagonist (the dashboard hero does).
    var fractionFont: Font?
    /// Letter spacing applied to the whole figure. Large protagonist figures
    /// want a slight negative value; the default 0 leaves list figures alone.
    var tracking: CGFloat = 0
    var tone: Tone = .standard

    var body: some View {
        let formatted = TraccioCore.formatMoney(
            amount: amount, currencyCode: currencyCode, explicitSign: explicitSign
        )
        return figure(formatted)
            .tracking(tracking)
            .accessibilityLabel(formatted)
    }

    @ViewBuilder
    private func figure(_ formatted: String) -> some View {
        if let split = Self.splitFraction(formatted) {
            (
                Text(split.head).font(font).foregroundStyle(color).monospacedDigit()
                    + Text(split.fraction).font(fractionFont ?? font)
                    .foregroundStyle(fractionColor).monospacedDigit()
            )
        } else {
            Text(formatted).font(font).foregroundStyle(color).monospacedDigit()
        }
    }

    /// Split a formatted figure into everything-before-the-cents and the
    /// ",dd" tail. Italian formatting only (the client is Italian-only,
    /// `client/CLAUDE.md`): the decimal separator is "," and there are always
    /// exactly two fraction digits. Any other shape (the "XXX" wallet
    /// fallback, a future locale change) returns `nil` and the caller renders
    /// the whole string in one run.
    static func splitFraction(_ s: String) -> (head: String, fraction: String)? {
        guard let comma = s.lastIndex(of: ","),
            s.distance(from: s.index(after: comma), to: s.endIndex) == 2,
            s[s.index(after: comma)...].allSatisfy(\.isNumber)
        else { return nil }
        return (String(s[..<comma]), String(s[comma...]))
    }

    private var explicitSign: Bool {
        switch kind {
        case .spending, .notCounted: false
        case .income, .net: true
        }
    }

    private var color: Color {
        if tone == .onHero { return Palette.onHero }
        switch kind {
        case .spending: return Palette.ink
        case .income: return Palette.income
        case .net: return amount > 0 ? Palette.accent : Palette.ink
        case .notCounted: return Palette.inkQuaternary
        }
    }

    /// The cents run. Recedes for a spend or a non-counted leg (whole units
    /// read first); stays the figure colour for income / positive net, where
    /// a grey tail on a green number would look broken.
    private var fractionColor: Color {
        if tone == .onHero { return Palette.onHeroSecondary }
        switch kind {
        case .spending: return Palette.inkTertiary
        case .notCounted: return Palette.inkQuaternary
        case .income: return Palette.income
        case .net: return amount > 0 ? Palette.accent : Palette.inkTertiary
        }
    }
}
