import SwiftUI
import TraccioCore

/// "Eventi" — the caller's events: a trip, a renovation, any occasion whose
/// transactions the user wants grouped for a single net total. Reached from
/// the Impostazioni tab (ADR 0009).
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
                .padding(20)
        }
        .background(Palette.background)
        .navigationTitle("Eventi")
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $isPresentingCreateSheet) {
            CreateEventSheet(
                isSaving: model.isUpdating,
                failureMessage: model.actionFailure != nil ? failureMessage : nil,
                onSave: { name, startDate, endDate in
                    Task {
                        await model.createEvent(name: name, startDate: startDate, endDate: endDate)
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
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        case .loaded(let events):
            VStack(alignment: .leading, spacing: 16) {
                if model.actionFailure != nil {
                    Banner(message: failureMessage)
                }
                eventsCard(events)
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

    private func eventsCard(_ events: [EventResponse]) -> some View {
        Card {
            EyebrowLabel(text: "Eventi")
            if events.isEmpty {
                Text(
                    "Non hai ancora nessun evento. Crea un evento per raggruppare i movimenti di un'occasione — un viaggio, una ristrutturazione — e vedere quanto è costata davvero."
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        NavigationLink {
                            EventDetailView(
                                event: event,
                                client: client,
                                onEventChange: { model.replace($0) },
                                onEventDeleted: { model.remove(id: $0) }
                            )
                        } label: {
                            EventRow(event: event)
                        }
                        .buttonStyle(.plain)
                        if event.id != events.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
            Divider().overlay(Palette.separator)
            PillButton(title: "Nuovo evento", action: { isPresentingCreateSheet = true })
        }
    }
}
