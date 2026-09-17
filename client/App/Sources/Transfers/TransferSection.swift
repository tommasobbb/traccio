import SwiftUI
import TraccioCore

/// The transfer-specific card on `TransactionDetailView`: the counterpart
/// leg and an "Annulla collegamento" action — rendered only for a
/// transaction whose `transfer` resolved.
///
/// Presentational only, same posture as `AdvanceSections`: the counterpart
/// leg is fetched by `TransactionDetailViewModel.loadTransferIfNeeded()` and
/// arrives via `init`. No mockup covers this
/// (`docs/design/canvas/TransactionDetail.dc.html` only covers the advance
/// case) — built from existing tokens/components.
struct TransferSection: View {
    /// The counterpart leg, once resolved. `nil` while loading or if the
    /// lookup failed — the card still renders, minus that line, rather than
    /// hiding the unlink action.
    let counterpart: TransactionResponse?
    let isUnlinking: Bool
    let onUnlink: () -> Void

    var body: some View {
        Card {
            EyebrowLabel(text: "Trasferimento")
            if let counterpart {
                counterpartRow(counterpart)
                Divider().overlay(Palette.separator)
            }
            unlinkRow
        }
    }

    private func counterpartRow(_ counterpart: TransactionResponse) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(counterpart.displayDescription ?? counterpart.description)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let date = counterpart.effectiveDate {
                    Text(TraccioCore.formatDate(date, style: .dayMonthYear))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            Spacer()
            AmountText(
                amount: counterpart.amount, currencyCode: counterpart.currency,
                kind: counterpart.amount < 0 ? .spending : .income, font: Typography.compactFigure
            )
        }
    }

    private var unlinkRow: some View {
        Button(action: onUnlink) {
            HStack(spacing: 6) {
                if isUnlinking {
                    ProgressView().controlSize(.mini)
                }
                Text("Annulla collegamento")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUnlinking)
    }

}
