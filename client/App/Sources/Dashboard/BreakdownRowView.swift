import SwiftUI
import TraccioCore

/// One row of `CategoryBreakdownList` — `IconTile` · name · a `Capsule` fill
/// bar in the category's own colour · percentage · amount · chevron, per
/// `TraccioCore.CategoryBreakdownRow`.
///
/// The row's body is a tap target for the drill-through to Movimenti
/// (`onDrillThrough`, `nil` for a direct-spending remainder row — see
/// `CategoryBreakdownList`'s doc comment on why that one row is not
/// drillable); the chevron is a **separate** tap target, outside that
/// button, so expand/collapse never fights the drill-through for the touch —
/// nesting a button inside another interactive control's hit area is the
/// kind of gesture ambiguity this sidesteps by keeping them siblings.
struct BreakdownRowView: View {
    let row: CategoryBreakdownRow
    let currency: String
    /// The currency's total spending, for this row's percentage-of-total —
    /// a ratio between two backend-supplied integers, not a financial
    /// derivation, same class of computation as `row.fillFraction`.
    let totalSpending: Int
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onDrillThrough: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let onDrillThrough {
                    Button(action: onDrillThrough) { rowContent }
                        .buttonStyle(.plain)
                } else {
                    rowContent
                }
            }
            if row.hasChildren {
                Button(action: onToggleExpanded) {
                    DisclosureChevron(isExpanded: isExpanded)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Comprimi" : "Espandi")
            }
        }
        .padding(.leading, row.depth == 0 ? 0 : 24)
        // The accessible representation for the whole row — name, amount,
        // percentage as text, since the donut itself stays
        // `.accessibilityHidden(true)`.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(onDrillThrough != nil ? [.isButton] : [])
        .rowScrollTransition()
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            IconTile(systemImage: (row.icon ?? .other).systemImageName, color: row.color, diameter: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    AmountText(
                        amount: row.amount, currencyCode: currency, kind: .spending,
                        font: Typography.caption.weight(.bold)
                    )
                }
                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Palette.neutralFill)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Palette.color(row.color))
                                    .frame(width: proxy.size.width * row.fillFraction)
                            }
                    }
                    .frame(height: 4)
                    Text(percentageText)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// `row.name` with the Italian fallback/suffix applied — presentation
    /// copy stays in the view layer, per `client/CLAUDE.md`.
    private var displayName: String {
        let base = row.name ?? "Senza categoria"
        return row.isDirectRemainder ? "\(base) · diretto" : base
    }

    private var percentageText: String {
        guard totalSpending > 0 else { return "0%" }
        let percentage = Int((Double(row.amount) / Double(totalSpending) * 100).rounded())
        return "\(percentage)%"
    }

    private var accessibilityLabel: String {
        let amountText = TraccioCore.formatMoney(amount: row.amount, currencyCode: currency)
        return "\(displayName), \(amountText), \(percentageText)"
    }
}
