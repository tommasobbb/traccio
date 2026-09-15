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

    /// A cheap discriminator for `.animation(_:value:)` — see
    /// `TransactionsView.stateTag`'s doc comment for why not `Equatable`.
    /// Folds in the headline spend total so a loaded→loaded change (a new
    /// period, an FX toggle) lands inside an animation transaction and the
    /// hero figure's `.contentTransition(.numericText())` rolls the digits
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
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.goToPrevious() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Periodo precedente")
                .disabled(!model.canGoToPrevious)

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
                .disabled(!model.canGoToNext)
            }
            .buttonStyle(.plain)
            // The period chevrons are navigation chrome, not a brand touch —
            // ink, not accent (2026-09-08 tone revision, second pass).
            .foregroundStyle(Palette.inkSecondary)

            Picker("Unità", selection: unitBinding) {
                Text("Mese").tag(CalendarPeriod.Unit.month)
                Text("Trimestre").tag(CalendarPeriod.Unit.quarter)
                Text("Anno").tag(CalendarPeriod.Unit.year)
            }
            .pickerStyle(.segmented)
            .segmentedPickerTint()
        }
        // A quiet flush card, not the old accent-tint block — the period
        // strip is navigation, not a headline, and the accent no longer wants
        // that much presence at the top of the screen (2026-09-08 tone
        // revision, Panoramica recompose). Glass here was tried and reverted
        // (`docs/decisions/0032-glass-on-raised-cards.md`).
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(Palette.separatorSubtle, lineWidth: 1)
        )
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
        // When the backend converted every currency into one base (ADR 0021,
        // opt-in), the hero and every breakdown come from that combined
        // summary; the per-currency figures move to a compact "Per valuta"
        // card. Otherwise it is the pre-FX behaviour: a chosen primary
        // currency up front, the rest listed separately and never summed.
        if let converted = summary.converted {
            heroCard(converted.summary)
            heroFootnote(converted.summary)
            conversionCaption(converted)

            if summary.currencies.count > 1 {
                otherCurrenciesCard(summary.currencies, combined: true)
            }
            breakdownCards(converted.summary)
            mealVoucherCards(summary.mealVouchers)
        } else if let primary = summary.currencies.primary() {
            heroCard(primary)
            heroFootnote(primary)

            let others = summary.currencies.filter { $0.currency != primary.currency }
            if !others.isEmpty {
                otherCurrenciesCard(others, combined: false)
            }
            if summary.conversionUnavailable != nil {
                Text("Totale combinato non disponibile al momento.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The donut / trend / account cards, all read from one
    /// `CurrencySummaryResponse` — the converted combined summary when FX is
    /// on, else the primary currency. Each renders nothing when it has
    /// nothing to show (pure-income period, no accounts). The period
    /// comparison is no longer a card here — it is a chunk of `heroFootnote`
    /// (2026-09-08 tone revision).
    @ViewBuilder
    private func breakdownCards(_ summary: CurrencySummaryResponse) -> some View {
        categoryBreakdownCard(summary)
        dailySpendingCard(summary)
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

    /// The "convertito in EUR ai tassi BCE · dd/MM" line under the converted
    /// hero. The date is the most recent rate actually applied.
    private func conversionCaption(_ converted: ConvertedSummaryResponse) -> some View {
        let latest = converted.rates.map(\.rateDate).max()
        let suffix = latest.map { " · \(String(format: "%02d/%02d", $0.day, $0.month))" } ?? ""
        return Text("Convertito in \(converted.summary.currency) ai tassi BCE\(suffix)")
            .font(Typography.caption)
            .foregroundStyle(Palette.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Panoramica's protagonist, and the app's first brand surface
    /// (`docs/decisions/0034-brand-triad.md`): `Palette.brandNight` instead
    /// of the plain white `Card` fill, still the only `.raised` card on the
    /// screen so the hierarchy is still carried by elevation and scale, not
    /// by being one colour block among others. The spend total — the "key
    /// figure on brandNight" the triad names directly — is `brandLime`
    /// instead of `ink`; every other run on this card that would otherwise
    /// read as `ink` (the eyebrow, "Entrate"/"Netto" labels, the divider)
    /// substitutes `brandCream` instead, via `AmountText.colorOverride` and
    /// explicit `foregroundStyle`s below. Income and a positive net keep
    /// their ordinary green untouched — the one thing this card doesn't
    /// change is what already reads as a semantic colour.
    private func heroCard(_ summary: CurrencySummaryResponse) -> some View {
        Card(elevation: .raised, background: Palette.brandNight) {
            VStack(alignment: .leading, spacing: 6) {
                EyebrowLabel(text: "Speso questo periodo", color: Palette.brandCream.opacity(0.7))
                AmountText(
                    amount: summary.spending,
                    currencyCode: summary.currency,
                    kind: .spending,
                    font: Typography.heroFigure,
                    fractionFont: Typography.statFigure,
                    tracking: -1.0,
                    colorOverride: Palette.brandLime
                )
                Text(summary.currency)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.brandCream.opacity(0.7))
            }

            categoryRibbon(summary)

            Divider().overlay(Palette.brandCream.opacity(0.18))

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Entrate")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.brandCream.opacity(0.7))
                    AmountText(amount: summary.income, currencyCode: summary.currency, kind: .income)
                }
                Rectangle()
                    .fill(Palette.brandCream.opacity(0.18))
                    .frame(width: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Netto")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.brandCream.opacity(0.7))
                    AmountText(
                        amount: summary.net, currencyCode: summary.currency, kind: .net,
                        colorOverride: Palette.brandCream
                    )
                }
            }
        }
    }

    /// A single quiet line under the hero card, on the background — the
    /// period comparison and the three secondary stats (media/giorno,
    /// movimenti, categorie) that used to be a second and third crammed
    /// section inside the hero body and a whole `ComparisonCard` of their
    /// own (2026-09-08 tone revision, Panoramica recompose). The comparison
    /// chunk keeps `ComparisonCard`'s old two-colour rule: a rise in spend is
    /// `warning`, a fall is `accent`.
    @ViewBuilder
    private func heroFootnote(_ summary: CurrencySummaryResponse) -> some View {
        let stats = [
            summary.averageDailySpending.map {
                "\(TraccioCore.formatMoney(amount: $0, currencyCode: summary.currency))/g"
            },
            "\(summary.transactionCount) mov.",
            "\(summary.byCategory.filter { $0.spending > 0 }.count) cat.",
        ].compactMap { $0 }

        HStack(spacing: 6) {
            if let comparison = summary.comparison {
                Image(systemName: comparisonImage(comparison))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(comparisonColor(comparison))
                Text(comparisonText(comparison, currency: summary.currency))
                    .font(Typography.caption)
                    .foregroundStyle(comparisonColor(comparison))
                Text("·").font(Typography.caption).foregroundStyle(Palette.inkQuaternary)
            }
            Text(stats.joined(separator: " · "))
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func comparisonImage(_ c: ComparisonSummaryResponse) -> String {
        if c.spendingDelta > 0 { return "arrow.up.right" }
        if c.spendingDelta < 0 { return "arrow.down.right" }
        return "minus"
    }

    /// Spending up carries `warning` (a genuine flag); spending down or flat
    /// stays ink — the direction is already in the words ("in meno"), and the
    /// dashboard keeps blue off its chrome (2026-09-08 tone revision, second
    /// pass).
    private func comparisonColor(_ c: ComparisonSummaryResponse) -> Color {
        if c.spendingDelta > 0 { return Palette.warning }
        return Palette.inkTertiary
    }

    /// "12% in più di agosto" / "12% in meno di agosto", or the signed
    /// amount when the previous period spent nothing (no percentage). The
    /// period label is the same `title(for:)` the picker uses.
    private func comparisonText(_ c: ComparisonSummaryResponse, currency: String) -> String {
        let previous = title(for: model.period.previous())
        guard let pct = c.spendingDeltaPct else {
            let amount = TraccioCore.formatMoney(
                amount: c.spendingDelta, currencyCode: currency, explicitSign: true
            )
            return "\(amount) su \(previous)"
        }
        let percentage = abs(Int((pct * 100).rounded()))
        let direction = c.spendingDelta > 0 ? "in più" : "in meno"
        return "\(percentage)% \(direction) di \(previous)"
    }

    /// The category-spend ribbon under the hero total (Fase B redesign, the
    /// "more colour" direction — `docs/design/canvas/MainV2.dc.html`): a
    /// full-width stacked bar in each root category's own `PaletteColor`,
    /// proportional to its spending, plus a compact legend of the top few.
    /// Drawn from `byCategory` — the same data the "Per categoria" donut
    /// uses, so no backend gap. Renders nothing when there is no spending to
    /// split, same posture as the donut card.
    @ViewBuilder
    private func categoryRibbon(_ summary: CurrencySummaryResponse) -> some View {
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
    /// rest — a glance key for the ribbon; the full labelled breakdown is
    /// the "Per categoria" card below. Text is `brandCream`, not `ink`/
    /// `inkTertiary`: this legend only ever renders inside `heroCard`'s
    /// `brandNight` surface (`docs/decisions/0034-brand-triad.md`).
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
                        .foregroundStyle(Palette.brandCream.opacity(0.8))
                        .lineLimit(1)
                }
                .layoutPriority(Double(shown.count - rank))
            }
            if spent.count > shown.count {
                Text("+\(spent.count - shown.count)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.brandCream.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
    }

    /// Per-currency net figures. `combined == false` is the pre-FX card:
    /// currencies *other* than the primary, explicitly not summed.
    /// `combined == true` lists *every* currency and notes that they are
    /// already folded into the converted total above.
    private func otherCurrenciesCard(
        _ others: [CurrencySummaryResponse], combined: Bool
    ) -> some View {
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
                EyebrowLabel(text: "Per categoria", color: Palette.ink)
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
                EyebrowLabel(text: "Andamento spesa", color: Palette.ink)
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
