import SwiftUI
import TraccioCore

/// "Eventi" — the caller's events: a trip, a renovation, any occasion whose
/// transactions the user wants grouped for a single net total. Reached from
/// the "Altro" tab (ADR 0009; moved there from Impostazioni by
/// `docs/decisions/0033-more-tab-and-settings-corner.md`).
///
/// No mockup covers this screen (`docs/design/canvas/` has no Eventi
/// artboard), so it is built from existing tokens/components, following
/// `CategorizationView`'s shape: one `Card` listing the rows, a "Nuova X"
/// button at the bottom. Pushed, so it has no `NavigationStack` of its own.
///
/// An event never changes a transaction's `role` or `effectiveAmount`
/// (`docs/domain.md` §Event) — membership is a reporting lens — so writes
/// here never need to invalidate `DataFreshness.Scope.dashboard` or
/// `.transactions`.
struct EventsView: View {
    @State private var model: EventsViewModel
    @State private var isPresentingCreateSheet = false
    private let client: any APIClientProtocol
    /// Shared between a row and its pushed `EventDetailView` so the push
    /// zooms from the row's own frame instead of sliding in
    /// (`docs/decisions/0030-liquid-glass-chrome.md`).
    @Namespace private var transitionNamespace

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend; also handed to
    ///     `EventDetailView` so both screens share one client instance.
    init(client: any APIClientProtocol = APIClient.current) {
        self.client = client
        _model = State(wrappedValue: EventsViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            content
                .padding(Spacing.gutter)
        }
        .screenChrome("Eventi")
        .animation(.easeInOut(duration: 0.2), value: model.state.tag)
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $isPresentingCreateSheet) {
            EventEditorSheet(
                isSaving: model.isUpdating,
                failureMessage: model.actionFailure != nil ? failureMessage : nil,
                onSave: { name, emoji, color, startDate, endDate in
                    Task {
                        await model.createEvent(
                            name: name, emoji: emoji, color: color,
                            startDate: startDate, endDate: endDate
                        )
                        if model.actionFailure == nil {
                            isPresentingCreateSheet = false
                        }
                    }
                },
                onCancel: { isPresentingCreateSheet = false }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ListSkeleton()
        case .loaded(let events):
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                if model.actionFailure != nil {
                    Banner(message: failureMessage)
                }
                if events.isEmpty {
                    emptyCard
                } else {
                    let active = events.filter { $0.status != .closed }
                    let closed = events.filter { $0.status == .closed }
                    if !active.isEmpty {
                        eventListCard(active, eyebrow: "Eventi")
                    }
                    if !closed.isEmpty {
                        eventListCard(closed, eyebrow: "Chiusi")
                    }
                    PillButton(title: "Nuovo evento", action: { isPresentingCreateSheet = true })
                }
            }
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare gli eventi",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.load() } }
            )
        }
    }

    private var failureMessage: String {
        "Non è stato possibile completare l'operazione. Riprova."
    }

    private var emptyCard: some View {
        Card {
            EyebrowLabel(text: "Eventi")
            Text(
                "Non hai ancora nessun evento. Crea un evento per raggruppare i movimenti di un'occasione — un viaggio, una ristrutturazione — e vedere quanto è costata davvero."
            )
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
            Divider().overlay(Palette.separator)
            PillButton(title: "Nuovo evento", action: { isPresentingCreateSheet = true })
        }
    }

    /// One section of events as a single `.resting` card — the day-card idiom
    /// from Movimenti (ADR 0008's tone revision): one border, one shadow,
    /// hairline dividers between self-padded rows.
    private func eventListCard(_ events: [EventResponse], eyebrow: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EyebrowLabel(text: eyebrow)
            Card(elevation: .resting, contentPadding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 {
                            Divider().overlay(Palette.separatorSubtle).padding(.leading, 16)
                        }
                        NavigationLink {
                            EventDetailView(
                                event: event,
                                client: client,
                                onEventChange: { model.replace($0) },
                                onEventDeleted: { model.remove(id: $0) }
                            )
                            #if os(iOS)
                            .navigationTransition(.zoom(sourceID: event.id, in: transitionNamespace))
                            #endif
                        } label: {
                            EventRow(event: event)
                                .padding(.horizontal, Spacing.cardPadding)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.pressableRow)
                        .matchedTransitionSource(id: event.id, in: transitionNamespace)
                    }
                }
            }
        }
    }
}
