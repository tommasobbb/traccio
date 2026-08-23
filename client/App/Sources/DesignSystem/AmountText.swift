import SwiftUI
import TraccioCore

/// Renders a money amount with the spend/income color convention baked in,
/// so no screen can color a spend red (or an income figure the wrong way)
/// by accident — the single place that decision is made.
///
/// Always uses tabular (monospaced) figures, per `docs/design/tokens.md`,
/// so columns of amounts align.
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
    }

    let amount: Int
    let currencyCode: String
    let kind: Kind
    var font: Font = Typography.statFigure

    var body: some View {
        Text(
            TraccioCore.formatMoney(
                amount: amount, currencyCode: currencyCode, explicitSign: explicitSign
            )
        )
        .font(font)
        .foregroundStyle(color)
        .monospacedDigit()
    }

    private var explicitSign: Bool {
        switch kind {
        case .spending: false
        case .income, .net: true
        }
    }

    private var color: Color {
        switch kind {
        case .spending: Palette.ink
        case .income: Palette.income
        case .net: amount > 0 ? Palette.accent : Palette.ink
        }
    }
}
