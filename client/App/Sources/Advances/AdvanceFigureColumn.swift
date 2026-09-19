import SwiftUI
import TraccioCore

/// A small "Atteso"/"Rientrato"-style figure pair column: a caption label
/// over a caption-scale `AmountText`. Shared between `PersonDetailView`'s
/// summary card and `AdvancesView`'s "Da ricevere" header (2026-09-19) — the
/// same anatomy, copied over from `PersonDetailView` (the drill-down) rather
/// than reinvented, so the screen a person lands on and the screen they came
/// from read as one system.
func advanceFigureColumn(label: String, amount: Int, currency: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label)
            .font(Typography.caption)
            .foregroundStyle(Palette.inkTertiary)
        AmountText(amount: amount, currencyCode: currency, kind: .notCounted, font: Typography.caption)
    }
}
