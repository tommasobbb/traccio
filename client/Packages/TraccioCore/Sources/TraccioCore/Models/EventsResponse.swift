/// Envelope for the event list returned by `GET /events`.
///
/// Mirrors the `EventsResponse` schema in `docs/api/openapi.json`. A wrapper
/// object rather than a bare array leaves room for pagination metadata later
/// without breaking decoding — same reasoning as `AdvancesResponse`.
public struct EventsResponse: Codable, Sendable {
    /// The user's events, oldest first (the backend's order — the view model
    /// sorts newest-first for display).
    public let events: [EventResponse]

    public init(events: [EventResponse]) {
        self.events = events
    }
}
