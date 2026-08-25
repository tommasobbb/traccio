import Foundation
import Observation
import TraccioCore

/// Drives `EventsView`: the caller's events, and creating a new one.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`client/CLAUDE.md`): `total`/`memberCount` are server-derived
/// (`domain/events.py::event_total`), this view model only renders them.
/// Nothing here logs or prints an event: its `name` is user-typed
/// (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class EventsViewModel {
    /// What the view should show right now.
    enum State {
        case idle
        case loading
        case loaded([EventResponse])
        case failed
    }

    /// Why creating an event failed, for the view to surface. Carries only a
    /// status-derived reason, never the response body
    /// (`.claude/rules/data-safety.md`) — same shape as
    /// `CategorizationViewModel.ActionFailure`.
    enum ActionFailure: Equatable {
        case generic
    }

    /// Current load state, observed by the view.
    private(set) var state: State = .idle
    /// Set while a create call is in flight, to disable the screen's
    /// controls rather than let two actions race.
    private(set) var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?

    /// Client used to reach the backend.
    private let client: any APIClientProtocol

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    init(client: any APIClientProtocol = APIClient.current) {
        self.client = client
    }

    /// Fetch the caller's events and publish the outcome.
    ///
    /// `GET /events` returns oldest-first; sorted newest-first here for
    /// display, since that is a presentation choice, not a derivation.
    func load() async {
        state = .loading
        do {
            let events = try await client.events()
            state = .loaded(events.sorted { $0.createdAt > $1.createdAt })
        } catch {
            state = .failed
        }
    }

    /// Create an event.
    ///
    /// On success, reloads the list rather than inserting the created event
    /// locally — the same discipline as `CategorizationViewModel`'s writes.
    ///
    /// Parameters
    /// ----------
    /// name:
    ///     The occasion's name.
    /// startDate:
    ///     Optional start of the date range.
    /// endDate:
    ///     Optional end of the date range.
    func createEvent(name: String, startDate: CalendarDate?, endDate: CalendarDate?) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            _ = try await client.createEvent(
                CreateEventRequest(name: name, startDate: startDate, endDate: endDate)
            )
            await load()
        } catch {
            actionFailure = .generic
        }
    }

    /// Replace one event's row in place after a successful write on the
    /// detail screen (a status change, or a membership change that moved
    /// `memberCount`/`total`) — mirrors `TransactionsViewModel.replace(_:)`,
    /// avoiding a full reload for a change the caller already has the fresh
    /// data for. A no-op if the list is not currently loaded, or the event
    /// is not in it.
    ///
    /// Parameters
    /// ----------
    /// updated:
    ///     The event's refreshed representation.
    func replace(_ updated: EventResponse) {
        guard case .loaded(var events) = state else { return }
        guard let index = events.firstIndex(where: { $0.id == updated.id }) else { return }
        events[index] = updated
        state = .loaded(events)
    }

    /// Remove one event's row in place after it was deleted on the detail
    /// screen. A no-op if the list is not currently loaded.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The deleted event's id.
    func remove(id: UUID) {
        guard case .loaded(var events) = state else { return }
        events.removeAll { $0.id == id }
        state = .loaded(events)
    }
}
