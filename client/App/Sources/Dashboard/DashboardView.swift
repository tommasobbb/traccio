import SwiftUI
import TraccioCore

/// The Panoramica (dashboard) screen — the first screen to render
/// `GET /dashboard/summary`, closing M2's "done when"
/// (`tasks/ROADMAP.md`: *"tag a real advance and watch the dashboard show my
/// actual share"*).
///
/// Follows the `docs/design/canvas/Main.dc.html` mockup, minus the two
/// elements it marks "Concept · richiede backend" (the category donut and the
/// trend line) and minus the recent-transactions list, which needs
/// `GET /transactions` — a later slice (ADR 0008's consequences section).
struct DashboardView: View {
    @State private var model = DashboardViewModel()
    /// Bumped by a write on another tab that can change this screen's
    /// numbers (e.g. applying categorization rules once a category
    /// breakdown exists — `tasks/backlog.md`). Keying `.task(id:)` to it
    /// triggers a full re-fetch, never a local recomputation.
    @Environment(DataFreshness.self) private var freshness

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Panoramica")
        }
        .task(id: freshness.token) { await model.load() }
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
                ContentUnavailableView {
                    Label("Impossibile caricare la panoramica", systemImage: "wifi.slash")
                } description: {
                    Text("Verifica che il backend sia in esecuzione, poi riprova.")
                }
                .frame(maxWidth: .infinity, minHeight: 240)
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
}

#Preview {
    DashboardView()
}
