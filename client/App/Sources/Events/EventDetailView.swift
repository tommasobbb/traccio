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
    @Environment(\.dismiss) private var dismiss

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
        client: any APIClientProtocol = APIClient.devDefault,
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
                    onDelete: { Task { await model.deleteEvent() } }
                )
            }
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle(model.event.name)
        .task { await model.loadMembers() }
        .sheet(isPresented: $isPresentingAddMembersSheet) {
            AddEventMembersSheet(
                candidates: model.availableCandidates,
                isUpdating: model.isUpdating,
                failureMessage: model.actionFailure != nil ? failureMessage : nil,
                onAssign: { id in Task { await model.assign(transactionID: id) } },
                onDone: { isPresentingAddMembersSheet = false }
            )
        }
        .onChange(of: model.wasDeleted) { _, wasDeleted in
            if wasDeleted { dismiss() }
        }
    }

    private var header: some View {
        Badge(
            text: model.event.status == .closed ? "Chiuso" : "Attivo",
            style: model.event.status == .closed ? .neutral : .accent
        )
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
}
