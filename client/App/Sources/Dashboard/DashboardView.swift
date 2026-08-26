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
    /// The channel a breakdown row's drill-through requests through — see
    /// `TransactionsDrillThrough`'s own doc comment for why this is a tab
    /// switch, not a `NavigationLink` push.
    @Environment(TransactionsDrillThrough.self) private var drillThrough
    /// The donut's fixed size — also the max width for its center label, so
    /// a category name doesn't overflow the ring's hole.
    private let donutDiameter: CGFloat = 96

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
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.goToPrevious() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Periodo precedente")

                Text(title(for: model.period))
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)

                Button {
                    Task { await model.goToNext() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Periodo successivo")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.inkTertiary)

            Picker("Unità", selection: unitBinding) {
                Text("Mese").tag(CalendarPeriod.Unit.month)
                Text("Trimestre").tag(CalendarPeriod.Unit.quarter)
                Text("Anno").tag(CalendarPeriod.Unit.year)
            }
            .pickerStyle(.segmented)
        }
    }

    private var unitBinding: Binding<CalendarPeriod.Unit> {
        Binding(
            get: { model.period.unit },
            set: { newUnit in Task { await model.changeUnit(newUnit) } }
        )
    }

    /// A display title for `period`, e.g. "agosto 2026" (month), "T3 2026"
    /// (quarter), "2026" (year) — locale-formatted where `DateFormatter` can
    /// do that (month, year), and a small Italian-only literal for the
    /// quarter label ("T" for "Trimestre"), consistent with the client being
    /// officially Italian-only (`client/CLAUDE.md`). Lives here, not on
    /// `CalendarPeriod` itself, per the same "display copy stays in the
    /// view" rule `TransactionPeriodPreset` and `TransactionsView.title(for:)`
    /// already follow.
    private func title(for period: CalendarPeriod) -> String {
        let formatter = DateFormatter()
        switch period.unit {
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: period.start).capitalized
        case .quarter:
            let calendar = Calendar.current
            let quarter = (calendar.component(.month, from: period.start) - 1) / 3 + 1
            let year = calendar.component(.year, from: period.start)
            return "T\(quarter) \(year)"
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
            return formatter.string(from: period.start)
        }
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

            // `comparison` is always requested (`DashboardViewModel.load()`),
            // but still optional on the wire — absent only if the backend
            // genuinely could not compute one, which should not happen given
            // `compareStart`/`compareEnd` are always both sent together.
            if let comparison = primary.comparison {
                ComparisonCard(
                    comparison: comparison, currency: primary.currency,
                    previousPeriodLabel: title(for: model.period.previous())
                )
            }

            AccountBreakdownCard(
                accounts: primary.byAccount, currency: primary.currency, totalSpending: primary.spending
            )
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
            Text(summary.currency)
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

            Divider().overlay(Palette.separator)

            HStack(spacing: 16) {
                statColumn(
                    title: "Media/giorno",
                    value: summary.averageDailySpending.map {
                        TraccioCore.formatMoney(amount: $0, currencyCode: summary.currency)
                    } ?? "—"
                )
                Rectangle().fill(Palette.separator).frame(width: 1)
                statColumn(title: "Movimenti", value: "\(summary.transactionCount)")
                Rectangle().fill(Palette.separator).frame(width: 1)
                statColumn(
                    title: "Categorie", value: "\(summary.byCategory.filter { $0.spending > 0 }.count)"
                )
            }
        }
    }

    /// One column of the hero card's stats row (media/giorno, movimenti,
    /// categorie) — all values the backend already computed or a plain
    /// count of already-fetched entries, never a financial derivation.
    private func statColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            Text(value)
                .font(Typography.compactFigure)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    ///
    /// 2026-08-26 revision (ADR 0008): the donut shrinks and gains tap-to-
    /// select, its center switches between the selected category and the
    /// period total, and the old position-paired side legend is replaced by
    /// `CategoryBreakdownList` — a full-width, expandable, drill-through-able
    /// list that is also this card's accessible representation of the
    /// (`.accessibilityHidden(true)`) donut.
    @ViewBuilder
    private func categoryBreakdownCard(_ summary: CurrencySummaryResponse) -> some View {
        let segments = TraccioCore.donutSegments(summary.byCategory)

        if !segments.isEmpty {
            Card {
                EyebrowLabel(text: "Per categoria")
                HStack {
                    Spacer(minLength: 0)
                    ZStack {
                        DonutChart(
                            segments: segments,
                            selection: model.selectedCategoryID,
                            onSelect: { model.selectCategory($0) },
                            diameter: donutDiameter
                        )
                        donutCenter(summary)
                    }
                    Spacer(minLength: 0)
                }
                CategoryBreakdownList(
                    rows: TraccioCore.breakdownRows(
                        groups: summary.byCategory, expanded: model.expandedRootIDs
                    ),
                    currency: summary.currency,
                    totalSpending: summary.spending,
                    expandedRootIDs: model.expandedRootIDs,
                    onToggleExpanded: { model.toggleExpanded($0) },
                    onDrillThrough: { categoryID in
                        drillThrough.request(model.drillThroughFilter(categoryID: categoryID))
                    }
                )
            }
        }
    }

    /// The donut's center label — the selected category's own name and
    /// amount, or the period total when nothing is selected. A selection
    /// whose category no longer resolves against `summary.byCategory` (a
    /// stale id after a reload race) falls back to the total, same as no
    /// selection at all.
    @ViewBuilder
    private func donutCenter(_ summary: CurrencySummaryResponse) -> some View {
        let selectedGroup: CategoryGroupSummaryResponse? = {
            guard case .category(let categoryID) = model.selectedCategoryID else { return nil }
            return summary.byCategory.first { $0.categoryID == categoryID }
        }()

        VStack(spacing: 2) {
            AmountText(
                amount: selectedGroup?.spending ?? summary.spending,
                currencyCode: summary.currency,
                kind: .spending,
                font: Typography.compactFigure
            )
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            Text(selectedGroup.map { $0.categoryName ?? "Senza categoria" } ?? "totale")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: donutDiameter - 32)
    }

    /// The trend card (`docs/design/canvas/Main.dc.html`'s "Andamento netto"
    /// slot, rebuilt as a spending bar chart rather than a net line — ADR
    /// 0007's 2026-08-25 revision). Renders nothing when there is nothing to
    /// show, same posture as `heroCard`'s and `categoryBreakdownCard`'s own
    /// empty branches.
    ///
    /// Uses the same period the rest of the screen shows — no independent
    /// selector. Bucketed at `period.granularity` (day/week/month per unit,
    /// Task 6), and the backend gap-fills `by_bucket` across the whole
    /// requested period since both bounds are always sent, so
    /// `spendingBars(_:)` never needs to reconcile a mismatch between the
    /// axis and `model.period`.
    @ViewBuilder
    private func dailySpendingCard(_ summary: CurrencySummaryResponse) -> some View {
        let bars = TraccioCore.spendingBars(summary.byBucket)

        if !bars.isEmpty {
            Card {
                EyebrowLabel(text: "Andamento spesa")
                BucketBarsChart(
                    bars: bars,
                    currency: summary.currency,
                    selectedIndex: model.selectedBucketIndex,
                    onScrub: { model.selectBucket($0) },
                    onDrillThrough: { index in
                        guard bars.indices.contains(index) else { return }
                        let bar = bars[index]
                        if let filter = model.drillThroughFilter(bucketStart: bar.start, bucketEnd: bar.end) {
                            drillThrough.request(filter)
                        }
                    }
                )
            }
        }
    }
}

#Preview {
    DashboardView()
}
