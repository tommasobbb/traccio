import SwiftUI
import TraccioCore

/// The Panoramica (dashboard) screen — the first screen to render
/// `GET /dashboard/summary`, closing M2's "done when"
/// (`tasks/ROADMAP.md`: *"tag a real advance and watch the dashboard show my
/// actual share"*).
///
/// Follows the `docs/design/canvas/Main.dc.html` mockup, minus the
/// recent-transactions list, which needs `GET /transactions` — a later slice
/// (ADR 0008's consequences section). The mockup's two "Concept · richiede
/// backend" elements — the category donut and the trend line — are both
/// built now: the trend renders as daily spending bars, not the mockup's
/// net line (`docs/decisions/0007-dashboard-aggregation.md`'s 2026-08-25
/// revision).
struct DashboardView: View {
    @State private var model = DashboardViewModel()
    /// `.dashboard` is bumped by a write on another tab that can change this
    /// screen's totals or category breakdown — applying categorization
    /// rules, confirming/clearing a category, a transfer confirm/reject/
    /// unlink, or an advance/reimbursement create/delete/write-off/reopen.
    /// Keying `.task(id:)` to it triggers a full re-fetch, never a local
    /// recomputation — see `DataFreshness`'s doc comment.
    @Environment(DataFreshness.self) private var freshness

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Panoramica")
            .animation(.easeInOut(duration: 0.2), value: stateTag)
        }
        .task(id: freshness.token(for: .dashboard)) { await model.load() }
    }

    /// A cheap discriminator for `.animation(_:value:)` — see
    /// `TransactionsView.stateTag`'s doc comment for why not `Equatable`.
    private var stateTag: String {
        switch model.state {
        case .idle, .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        case .loaded(let summary):
            VStack(alignment: .leading, spacing: 16) {
                periodPicker
                summaryContent(summary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 16) {
                periodPicker
                EmptyState(
                    systemImage: "wifi.slash",
                    title: "Impossibile caricare la panoramica",
                    description: "Verifica che il backend sia in esecuzione, poi riprova.",
                    tone: .warning,
                    actionTitle: "Riprova",
                    action: { Task { await model.load() } }
                )
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.goToPreviousMonth() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Mese precedente")

            Text(model.period.title)
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)

            Button {
                Task { await model.goToNextMonth() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Mese successivo")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.inkTertiary)
    }

    @ViewBuilder
    private func summaryContent(_ summary: DashboardSummaryResponse) -> some View {
        if let primary = summary.currencies.primary() {
            heroCard(primary)

            let others = summary.currencies.filter { $0.currency != primary.currency }
            if !others.isEmpty {
                otherCurrenciesCard(others)
            }

            // Only the primary currency gets a breakdown — same rule as the
            // hero card, and for the same reason: a donut mixing currencies
            // would misrepresent proportions Traccio never converts between
            // (ADR 0007). Renders nothing at all when this currency's period
            // was pure income (spending == 0), same as `DonutChart`'s own
            // empty case.
            categoryBreakdownCard(primary)

            // Same primary-currency-only rule as the two cards above, for
            // the same reason: a bar mixing currencies would misrepresent
            // magnitudes Traccio never converts between (ADR 0007).
            dailySpendingCard(primary)
        } else {
            Card {
                EyebrowLabel(text: "Speso questo periodo")
                Text("Nessun movimento in questo periodo.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private func heroCard(_ summary: CurrencySummaryResponse) -> some View {
        Card {
            EyebrowLabel(text: "Speso questo periodo")
            AmountText(
                amount: summary.spending,
                currencyCode: summary.currency,
                kind: .spending,
                font: Typography.heroFigure
            )
            Text("\(summary.transactionCount) movimenti · \(summary.currency)")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)

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

    private func otherCurrenciesCard(_ others: [CurrencySummaryResponse]) -> some View {
        Card {
            EyebrowLabel(text: "Altre valute")
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
            // Every currency stands alone — Traccio never converts between
            // currencies (ADR 0007), so these figures must never read as
            // parts of one combined total.
            Text("Non sommate all'importo principale — Traccio non applica cambi tra valute.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    /// The "Per categoria" card (`docs/design/canvas/Main.dc.html`), the
    /// mockup element the "Concept · richiede backend" badge blocked until
    /// `GET /dashboard/summary` started returning `by_category`. Renders
    /// nothing when there is nothing to show, rather than an empty donut —
    /// same posture as `heroCard`'s own empty-period branch above.
    @ViewBuilder
    private func categoryBreakdownCard(_ summary: CurrencySummaryResponse) -> some View {
        let segments = TraccioCore.donutSegments(summary.byCategory)
        // Mirrors donutSegments' own filter so each segment lines up with
        // exactly one legend row, in the same order — an income-only entry
        // (spending == 0) gets neither an arc nor a row.
        let entries = summary.byCategory.filter { $0.spending > 0 }

        if !segments.isEmpty {
            Card {
                EyebrowLabel(text: "Per categoria")
                HStack(alignment: .center, spacing: 20) {
                    ZStack {
                        DonutChart(segments: segments)
                        VStack(spacing: 2) {
                            AmountText(
                                amount: summary.spending,
                                currencyCode: summary.currency,
                                kind: .spending,
                                font: Typography.statFigure
                            )
                            Text("totale")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(zip(segments, entries)), id: \.0.rank) { segment, entry in
                            categoryLegendRow(segment: segment, entry: entry, currency: summary.currency)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func categoryLegendRow(
        segment: DonutSegment, entry: CategorySummaryResponse, currency: String
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.categoryChart(rank: segment.rank))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(entry.categoryName ?? "Senza categoria")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            AmountText(
                amount: entry.spending,
                currencyCode: currency,
                kind: .spending,
                font: Typography.caption.weight(.bold)
            )
        }
    }

    /// The "Spesa giornaliera" card (`docs/design/canvas/Main.dc.html`'s
    /// "Andamento netto" slot, rebuilt as a spending bar chart rather than a
    /// net line — the 2026-08-25 revision to ADR 0007). Renders nothing when
    /// there is nothing to show, same posture as `heroCard`'s and
    /// `categoryBreakdownCard`'s own empty branches.
    ///
    /// Uses the same period the rest of the screen shows — no independent
    /// selector — but the axis itself is whatever UTC days `dailyBars(_:)`
    /// returns, which is `by_day`'s own earliest-to-latest span, not
    /// necessarily every day of `model.period` (see `dailyBars(_:)`'s doc
    /// comment on why the two are not reconciled).
    @ViewBuilder
    private func dailySpendingCard(_ summary: CurrencySummaryResponse) -> some View {
        let bars = TraccioCore.dailyBars(summary.byDay)

        if let first = bars.first, let last = bars.last {
            Card {
                EyebrowLabel(text: "Spesa giornaliera")
                DailyBarsChart(bars: bars)
                HStack {
                    Text(TraccioCore.formatCalendarDate(first.day))
                    Spacer()
                    Text(TraccioCore.formatCalendarDate(last.day))
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

#Preview {
    DashboardView()
}
