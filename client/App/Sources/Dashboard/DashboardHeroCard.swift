import SwiftUI
import TraccioCore

/// Panoramica's protagonist. Since the 2026-09-08 "dose, non tinta" revision
/// this is a plain `Card` at `.raised` — the only raised card on the screen,
/// so the hierarchy is carried by elevation and the figure's own scale, not
/// by a filled colour band (`docs/design/tokens.md`'s "Accent dosage"). The
/// spend total is `ink`, big, with tight tracking.
struct DashboardHeroCard: View {
    let summary: CurrencySummaryResponse

    var body: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 6) {
                EyebrowLabel(text: "Speso questo periodo")
                AmountText(
                    amount: summary.spending,
                    currencyCode: summary.currency,
                    kind: .spending,
                    font: Typography.heroFigure,
                    fractionFont: Typography.statFigure,
                    tracking: -1.0
                )
                Text(summary.currency)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }

            categoryRibbon

            Divider().overlay(Palette.separator)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Entrate")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                    AmountText(amount: summary.income, currencyCode: summary.currency, kind: .income)
                }
                Rectangle()
                    .fill(Palette.separator)
                    .frame(width: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Netto")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                    AmountText(amount: summary.net, currencyCode: summary.currency, kind: .net)
                }
            }
        }
    }

    /// The category-spend ribbon under the hero total (Fase B redesign, the
    /// "more colour" direction — `docs/design/canvas/MainV2.dc.html`): a
    /// full-width stacked bar in each root category's own `PaletteColor`,
    /// proportional to its spending, plus a compact legend of the top few.
    /// Drawn from `byCategory` — the same data the "Per categoria" donut
    /// uses, so no backend gap. Renders nothing when there is no spending to
    /// split, same posture as the donut card.
    @ViewBuilder
    private var categoryRibbon: some View {
        let segments = TraccioCore.donutSegments(summary.byCategory)
        let spent = summary.byCategory.filter { $0.spending > 0 }

        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    // Each segment positioned by its own fraction rather than
                    // laid out in an `HStack` whose widths (each `max(_, 2)`-
                    // clamped, plus 1pt spacing) sum past `geo.size.width` and
                    // silently clip the tail on quarter/year periods, where
                    // there are many small categories.
                    ZStack(alignment: .leading) {
                        ForEach(segments, id: \.rank) { segment in
                            Palette.color(segment.color)
                                .frame(
                                    width: max(
                                        geo.size.width
                                            * (segment.endFraction - segment.startFraction),
                                        1
                                    )
                                )
                                .offset(x: geo.size.width * segment.startFraction)
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())

                ribbonLegend(spent)
            }
        }
    }

    /// Up to three top spenders as coloured dot + name, then "+N" for the
    /// rest — a glance key for the ribbon; the full labelled breakdown is the
    /// "Per categoria" card below.
    private func ribbonLegend(_ spent: [CategoryGroupSummaryResponse]) -> some View {
        let shown = Array(spent.prefix(3))
        return HStack(spacing: 12) {
            ForEach(Array(shown.enumerated()), id: \.element.categoryID) { rank, entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Palette.color(entry.color ?? .slate))
                        .frame(width: 7, height: 7)
                    // No `.fixedSize` here: three full Italian category names
                    // exceed the card width and would force the hero card —
                    // and the whole content column — wider than the viewport.
                    // The label truncates instead; the higher-spend items keep
                    // their width first via `layoutPriority`.
                    Text(entry.categoryName ?? "Senza categoria")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
                .layoutPriority(Double(shown.count - rank))
            }
            if spent.count > shown.count {
                Text("+\(spent.count - shown.count)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
