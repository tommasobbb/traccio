import SwiftUI
import TraccioCore

/// Per-currency net figures. `combined == false` is the pre-FX card:
/// currencies *other* than the primary, explicitly not summed. `combined ==
/// true` lists *every* currency and notes that they are already folded into
/// the converted total shown above it.
struct OtherCurrenciesCard: View {
    let others: [CurrencySummaryResponse]
    let combined: Bool

    var body: some View {
        Card {
            EyebrowLabel(text: combined ? "Per valuta" : "Altre valute", color: Palette.ink)
            HStack(spacing: 10) {
                ForEach(others, id: \.currency) { summary in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.currency)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                        AmountText(
                            amount: summary.net,
                            currencyCode: summary.currency,
                            kind: .net,
                            font: Typography.compactFigure
                        )
                        Text("\(summary.transactionCount) movimenti")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.neutralFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            Text(
                combined
                    ? "Già incluse nell'importo convertito qui sopra, ai tassi BCE."
                    : "Non sommate all'importo principale — Traccio non applica cambi tra valute."
            )
            .font(Typography.caption)
            .foregroundStyle(Palette.inkTertiary)
        }
    }
}
