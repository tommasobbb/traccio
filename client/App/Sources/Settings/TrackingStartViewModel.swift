import Foundation
import Observation
import TraccioCore

/// Drives `TrackingStartView`: loads the current tracking start date and the
/// per-account suggestion (ADR 0024), and saves or clears the date.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`client/CLAUDE.md`). Nothing here logs a movement.
@MainActor
@Observable
final class TrackingStartViewModel {
    /// What the screen should show.
    enum State: Equatable {
        case loading
        case loaded(current: CalendarDate?, suggestion: TrackingStartSuggestionResponse)
        case failed
    }

    private(set) var state: State = .loading
    /// Set while a save/clear call is in flight.
    private(set) var isSaving = false
    /// The last save failed — the view shows a retry-able message.
    private(set) var saveFailed = false
    /// Account id → its `PaletteColor` (falling back to `.slate`), so the
    /// timeline can draw each account's bar in its own colour. Loaded
    /// alongside the suggestion; empty until then and if the accounts call
    /// fails (the timeline just falls back to `.slate`).
    private(set) var accountColors: [UUID: PaletteColor] = [:]

    private let client: any APIClientProtocol
    /// Invoked after a successful save so the caller can mark the dashboard
    /// and Movimenti stale — the floor changes what both show.
    private let onChanged: () -> Void

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onChanged:
    ///     Called after a successful save/clear. Defaults to a no-op.
    init(
        client: any APIClientProtocol = APIClient.current,
        onChanged: @escaping () -> Void = {}
    ) {
        self.client = client
        self.onChanged = onChanged
    }

    /// Load the current value, the suggestion, and the accounts' colours, in
    /// parallel.
    func load() async {
        state = .loading
        do {
            async let settings = client.settings()
            async let suggestion = client.trackingStartSuggestion()
            async let accounts = client.accounts()
            let (current, suggested, accts) = try await (
                settings.trackingStartDate, suggestion, accounts
            )
            accountColors = Dictionary(
                accts.map { ($0.id, $0.color ?? .slate) }, uniquingKeysWith: { first, _ in first }
            )
            state = .loaded(current: current, suggestion: suggested)
        } catch {
            state = .failed
        }
    }

    /// Set the tracking start to `date` (or clear it with `nil`).
    ///
    /// On success the loaded state's `current` is replaced in place — the
    /// suggestion does not change — and `onChanged` fires. A no-op while
    /// another save is in flight.
    func save(_ date: CalendarDate?) async {
        guard !isSaving else { return }
        guard case .loaded(_, let suggestion) = state else { return }
        isSaving = true
        defer { isSaving = false }
        saveFailed = false
        do {
            let updated = try await client.setTrackingStart(date)
            state = .loaded(current: updated.trackingStartDate, suggestion: suggestion)
            onChanged()
        } catch {
            saveFailed = true
        }
    }
}
