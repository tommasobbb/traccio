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
///
/// The card-sized pieces (`DashboardPeriodPicker`, `DashboardHeroCard`,
/// `DashboardStatsCard`, `CategoryBreakdownCard`, `DailySpendingCard`,
/// `OtherCurrenciesCard`, `AccountBreakdownCard`, `MealVoucherCard`) each
/// live in their own file next to this one — this view only wires them to
/// `DashboardViewModel` and lays them out.
struct DashboardView: View {
    @State private var model = DashboardViewModel()
    /// `.dashboard` is bumped by a write on another tab that can change this
    /// screen's totals or category breakdown — applying categorization
    /// rules, confirming/clearing a category, a transfer confirm/reject/
    /// unlink, or an advance/reimbursement create/delete/write-off/reopen.
    /// Keying `.task(id:)` to it triggers a full re-fetch, never a local
    /// recomputation — see `DataFreshness`'s doc comment.
    @Environment(DataFreshness.self) private var freshness
    /// The channel a breakdown row's drill-through requests through — see
    /// `TransactionsDrillThrough`'s own doc comment for why this is a tab
    /// switch, not a `NavigationLink` push.
    @Environment(TransactionsDrillThrough.self) private var drillThrough

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(Spacing.gutter)
            }
            .screenChrome("Panoramica", style: .tabRoot)
            // Large, collapsing on scroll, like the other three tabs
            // (`docs/decisions/0031-visual-coherence-pass.md`) — a revision
            // of the 2026-09-08 "dose, non tinta" call to keep this screen
            // `.inline` so the hero figure alone carried the top. On-device
            // judgment call: if the title fights the figure for
            // "protagonist", this reverts and every tab goes `.pushed`
            // instead (`tasks/backlog.md`'s on-device pass).
            .animation(.easeInOut(duration: 0.2), value: stateTag)
            .toolbar { toolbarContent }
        }
        .task(id: freshness.token(for: .dashboard)) { await model.load() }
    }

    /// A cheap discriminator for `.animation(_:value:)`, richer than
    /// `LoadState.tag` (see its doc comment for why not `Equatable`): folds
    /// in the headline spend total so a loaded→loaded change (a new period,
    /// an FX toggle) lands inside an animation transaction and the hero
    /// figure's `.contentTransition(.numericText())` rolls the digits
    /// instead of snapping.
    private var stateTag: String {
        switch model.state {
        case .idle, .loading: return "loading"
        case .loaded(let summary):
            let spend = summary.converted?.summary.spending
                ?? summary.currencies.primary()?.spending
            return "loaded-\(spend ?? 0)"
        case .failed: return "failed"
        }
    }

    // MARK: Toolbar

    /// Panoramica's one toolbar entry: Impostazioni, pushed into this
    /// screen's own `NavigationStack`. This tab was chosen over Movimenti/
    /// Conti as the settings entry point precisely because it's the only
    /// tab root without a toolbar of its own already
    /// (`docs/decisions/0033-more-tab-and-settings-corner.md`) — the reason
    /// ADR 0009 originally gave for rejecting a gear icon here no longer
    /// applies once the icon has a real dedicated corner to sit in.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            NavigationLink {
                SettingsView()
            } label: {
                Label("Impostazioni", systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            DashboardSkeleton()
        case .loaded(let summary):
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                periodPicker
                summaryContent(summary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var periodPicker: some View {
        DashboardPeriodPicker(
            period: model.period,
            canGoToPrevious: model.canGoToPrevious,
            canGoToNext: model.canGoToNext,
            onPrevious: { Task { await model.goToPrevious() } },
            onNext: { Task { await model.goToNext() } },
            onChangeUnit: { newUnit in Task { await model.changeUnit(newUnit) } }
        )
    }

    @ViewBuilder
    private func summaryContent(_ summary: DashboardSummaryResponse) -> some View {
        // When the backend converted every currency into one base (ADR 0021,
        // opt-in), the hero and every breakdown come from that combined
        // summary; the per-currency figures move to a compact "Per valuta"
        // card. Otherwise it is the pre-FX behaviour: a chosen primary
        // currency up front, the rest listed separately and never summed.
        if let converted = summary.converted {
            DashboardHeroCard(summary: converted.summary)
            statsCard(converted.summary, caption: conversionCaptionText(converted))

            if summary.currencies.count > 1 {
                OtherCurrenciesCard(others: summary.currencies, combined: true)
            }
            breakdownCards(converted.summary)
            mealVoucherCards(summary.mealVouchers)
        } else if let primary = summary.currencies.primary() {
            let caption =
                summary.conversionUnavailable != nil
                ? "Totale combinato non disponibile al momento." : nil
            DashboardHeroCard(summary: primary)
            statsCard(primary, caption: caption)

            let others = summary.currencies.filter { $0.currency != primary.currency }
            if !others.isEmpty {
                OtherCurrenciesCard(others: others, combined: false)
            }
            breakdownCards(primary)
            mealVoucherCards(summary.mealVouchers)
        } else {
            Card {
                EyebrowLabel(text: "Speso questo periodo")
                Text("Nessun movimento in questo periodo.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private func statsCard(_ summary: CurrencySummaryResponse, caption: String?) -> some View {
        DashboardStatsCard(
            summary: summary,
            previousPeriodTitle: model.period.previous().displayTitle,
            caption: caption
        )
    }

    /// The donut / trend / account cards, all read from one
    /// `CurrencySummaryResponse` — the converted combined summary when FX is
    /// on, else the primary currency. Each renders nothing when it has
    /// nothing to show (pure-income period, no accounts). The period
    /// comparison is no longer a card here — it is `DashboardStatsCard`
    /// (2026-09-08 tone revision, 2026-09-19 recompose into its own card).
    @ViewBuilder
    private func breakdownCards(_ summary: CurrencySummaryResponse) -> some View {
        CategoryBreakdownCard(
            summary: summary,
            selectedCategoryID: model.selectedCategoryID,
            expandedRootIDs: model.expandedRootIDs,
            onSelectCategory: { model.selectCategory($0) },
            onToggleExpanded: { model.toggleExpanded($0) },
            onDrillThrough: { categoryID in
                drillThrough.request(model.drillThroughFilter(categoryID: categoryID))
            }
        )
        DailySpendingCard(
            summary: summary,
            selectedBucketIndex: model.selectedBucketIndex,
            onScrub: { model.selectBucket($0) },
            onDrillThrough: { start, end in
                if let filter = model.drillThroughFilter(bucketStart: start, bucketEnd: end) {
                    drillThrough.request(filter)
                }
            }
        )
        AccountBreakdownCard(
            accounts: summary.byAccount, currency: summary.currency, totalSpending: summary.spending
        )
    }

    /// One `MealVoucherCard` per currency with voucher spend (ADR 0029) —
    /// independent of `breakdownCards`' primary/converted choice, since the
    /// breakout is never FX-converted and a voucher account's currency need
    /// not match whichever currency the hero figure happens to feature.
    /// Empty (renders nothing) when the setting is off or there was no
    /// voucher spend this period.
    @ViewBuilder
    private func mealVoucherCards(_ mealVouchers: [MealVoucherSummaryResponse]) -> some View {
        ForEach(mealVouchers, id: \.currency) { MealVoucherCard(summary: $0) }
    }

    /// The "convertito in EUR ai tassi BCE · dd/MM" caption, folded into
    /// `DashboardStatsCard` rather than rendered as its own loose line. The
    /// date is the most recent rate actually applied.
    private func conversionCaptionText(_ converted: ConvertedSummaryResponse) -> String {
        let latest = converted.rates.map(\.rateDate).max()
        let suffix = latest.map { " · \(String(format: "%02d/%02d", $0.day, $0.month))" } ?? ""
        return "Convertito in \(converted.summary.currency) ai tassi BCE\(suffix)"
    }
}

#Preview {
    DashboardView()
}
