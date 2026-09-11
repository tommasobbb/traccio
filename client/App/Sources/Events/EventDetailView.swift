import SwiftUI
import TraccioCore

/// "Dettaglio evento" — reached by tapping a row in `EventsView`. Shows the
/// event's derived net total and member count, lists its member
/// transactions with per-row removal, and offers closing/reopening,
/// assigning new members, and deleting the event.
///
/// No mockup covers this screen (`docs/design/canvas/` has no Eventi
/// artboard), so it is built from existing tokens/components — same posture
/// as the categorization and transfer screens. `EventSections` holds the
/// event-specific cards, mirroring how `AdvanceSections` sits inside
/// `TransactionDetailView`.
struct EventDetailView: View {
    @State private var model: EventDetailViewModel
    @State private var isPresentingAddMembersSheet = false
    @State private var isPresentingEditSheet = false
    @Environment(\.dismiss) private var dismiss
    @Environment(TransactionsDrillThrough.self) private var drillThrough

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// event:
    ///     The event to show and act on.
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onEventChange:
    ///     Called with the refreshed event after a successful write, so the
    ///     caller (`EventsView`) can update its list row in place. Defaults
    ///     to a no-op for previews and callers that don't need it.
    /// onEventDeleted:
    ///     Called with the event's id after a successful delete. Defaults to
    ///     a no-op.
    init(
        event: EventResponse,
        client: any APIClientProtocol = APIClient.current,
        onEventChange: @escaping (EventResponse) -> Void = { _ in },
        onEventDeleted: @escaping (UUID) -> Void = { _ in }
    ) {
        _model = State(
            wrappedValue: EventDetailViewModel(
                event: event, client: client, onEventChange: onEventChange, onEventDeleted: onEventDeleted
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.actionFailure != nil {
                    Banner(message: failureMessage)
                }
                EventSections(
                    event: model.event,
                    members: model.members,
                    isUpdating: model.isUpdating,
                    onUnassign: { id in Task { await model.unassign(transactionID: id) } },
                    onAddMembers: {
                        Task { await model.loadCandidatesIfNeeded() }
                        isPresentingAddMembersSheet = true
                    },
                    onClose: { Task { await model.closeEvent() } },
                    onReopen: { Task { await model.reopenEvent() } },
                    onDelete: { Task { await model.deleteEvent() } },
                    breakdownCard: breakdownCard,
                    suggestionsCard: suggestionsCard
                )
            }
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle(model.event.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Modifica") { isPresentingEditSheet = true }
                    .disabled(model.isUpdating)
            }
        }
        .task {
            await model.loadMembers()
            await model.loadSummary()
            await model.loadSuggestions()
        }
        .sheet(isPresented: $isPresentingAddMembersSheet) {
            AddEventMembersSheet(
                candidates: model.availableCandidates,
                isUpdating: model.isUpdating,
                failureMessage: model.actionFailure != nil ? failureMessage : nil,
                onAssign: { id in Task { await model.assign(transactionID: id) } },
                onDone: { isPresentingAddMembersSheet = false }
            )
        }
        .sheet(isPresented: $isPresentingEditSheet) {
            EventEditorSheet(
                existing: model.event,
                isSaving: model.isUpdating,
                failureMessage: model.actionFailure != nil ? failureMessage : nil,
                onSave: { name, emoji, color, startDate, endDate in
                    Task {
                        await model.updateEvent(
                            name: name, emoji: emoji, color: color,
                            startDate: startDate, endDate: endDate
                        )
                        if model.actionFailure == nil {
                            isPresentingEditSheet = false
                        }
                    }
                },
                onCancel: { isPresentingEditSheet = false }
            )
        }
        .onChange(of: model.wasDeleted) { _, wasDeleted in
            if wasDeleted { dismiss() }
        }
    }

    /// The protagonist card — the only `.raised` one on the screen, so it
    /// leads through elevation and the figure's scale, not a colour block
    /// (ADR 0008's "dose, non tinta"). Tile + name + status, then the net
    /// total, then a single quiet footnote line.
    private var header: some View {
        Card(elevation: .raised) {
            HStack(spacing: 12) {
                EventTile(emoji: model.event.emoji, color: model.event.color, diameter: 40)
                Text(model.event.name)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Badge(
                    text: model.event.status == .closed ? "Chiuso" : "Attivo",
                    style: model.event.status == .closed ? .neutral : .accent
                )
            }
            if let currency = model.event.currency {
                AmountText(
                    amount: model.event.total, currencyCode: currency,
                    kind: .net, font: Typography.heroFigure
                )
            } else {
                Text("Nessun movimento assegnato")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Text(footnote)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    /// "N movimenti · 3–17 mag · 4 categorie" — the category count appears
    /// once the breakdown has loaded.
    private var footnote: String {
        var parts: [String] = [
            model.event.memberCount == 1 ? "1 movimento" : "\(model.event.memberCount) movimenti"
        ]
        if let range = dateRangeLabel {
            parts.append(range)
        }
        if let count = model.summary?.byCategory.count, count > 0 {
            parts.append(count == 1 ? "1 categoria" : "\(count) categorie")
        }
        return parts.joined(separator: " · ")
    }

    private var dateRangeLabel: String? {
        guard let start = model.event.startDate else { return nil }
        return TraccioCore.formatCalendarDateRange(from: start, to: model.event.endDate)
    }

    private var failureMessage: String {
        switch model.actionFailure {
        case .transactionInAnotherEvent:
            "Questo movimento è già in un altro evento."
        case .mixedCurrency:
            "Questo movimento è in una valuta diversa da quella dell'evento."
        case .generic, .none:
            "Non è stato possibile completare l'operazione. Riprova."
        }
    }

    /// The "Movimenti suggeriti" card (ADR 0028): un-grouped transactions
    /// dated within the event's range, each added with an explicit tap (never
    /// auto-assigned), plus an "Aggiungi tutti" behind confirmation. `nil`
    /// when there is nothing to suggest.
    private var suggestionsCard: AnyView? {
        guard !model.suggestions.isEmpty else { return nil }
        return AnyView(
            Card {
                HStack {
                    EyebrowLabel(text: "Movimenti suggeriti")
                    Spacer()
                    Text(model.suggestions.count == 1 ? "1 nel periodo" : "\(model.suggestions.count) nel periodo")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
                VStack(spacing: 0) {
                    ForEach(model.suggestions) { suggestion in
                        HStack(spacing: 12) {
                            Text(suggestion.displayDescription ?? suggestion.description)
                                .font(Typography.body)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Spacer()
                            AmountText(
                                amount: suggestion.amount, currencyCode: suggestion.currency,
                                kind: suggestion.amount < 0 ? .spending : .income,
                                font: Typography.caption
                            )
                            IconButton(
                                systemImage: "plus.circle",
                                accessibilityLabel: "Aggiungi all'evento",
                                isLoading: model.isUpdating,
                                action: { Task { await model.assign(transactionID: suggestion.id) } }
                            )
                        }
                        .padding(.vertical, 6)
                        if suggestion.id != model.suggestions.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
                Divider().overlay(Palette.separator)
                PillButton(
                    title: "Aggiungi tutti",
                    isLoading: model.isUpdating,
                    action: { Task { await model.assignAllSuggestions() } }
                )
            }
        )
    }

    /// The per-category breakdown card (ADR 0028), reusing the dashboard's
    /// `DonutChart` + `CategoryBreakdownList` unchanged. `nil` — an empty
    /// event, or the fetch failed — so `EventSections` omits it. A row drills
    /// through to Movimenti filtered to this event *and* that category, via
    /// the same cross-tab `TransactionsDrillThrough` the dashboard uses.
    private var breakdownCard: AnyView? {
        guard let summary = model.summary, let currency = summary.currency else { return nil }
        let segments = TraccioCore.donutSegments(summary.byCategory)
        guard !segments.isEmpty else { return nil }

        return AnyView(
            Card {
                EyebrowLabel(text: "Per categoria")
                HStack {
                    Spacer(minLength: 0)
                    DonutChart(
                        segments: segments,
                        selection: model.selectedCategory,
                        onSelect: { model.selectCategory($0) },
                        diameter: 132
                    )
                    Spacer(minLength: 0)
                }
                CategoryBreakdownList(
                    rows: TraccioCore.breakdownRows(
                        groups: summary.byCategory, expanded: model.expandedCategoryRootIDs
                    ),
                    currency: currency,
                    totalSpending: summary.spending,
                    expandedRootIDs: model.expandedCategoryRootIDs,
                    onToggleExpanded: { model.toggleCategoryExpanded($0) },
                    onDrillThrough: { categoryID in
                        let category: TransactionFilter.CategoryFilter =
                            categoryID.map { .some($0) } ?? .uncategorized
                        drillThrough.request(
                            TransactionFilter(eventID: model.event.id, category: category)
                        )
                    }
                )
            }
        )
    }
}
