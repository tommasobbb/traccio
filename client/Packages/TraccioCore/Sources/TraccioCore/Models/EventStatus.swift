/// Lifecycle state of an event.
///
/// Mirrors the `EventStatus` schema in `docs/api/openapi.json`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as `AdvanceStatus`.
public enum EventStatus: String, Codable, Sendable, CaseIterable {
    /// Open to new members; the default when an event is created.
    case active
    /// No longer accepting new members. Still readable and its members can
    /// still be unassigned — closing is a reporting boundary, not a lock.
    case closed
}
