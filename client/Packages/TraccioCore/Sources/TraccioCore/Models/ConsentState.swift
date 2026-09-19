/// The actual, time-aware state of a bank connection's consent.
///
/// Mirrors the `ConsentState` schema in `docs/api/openapi.json`. This is
/// `status` re-read against `expires_at` and the current time, derived once
/// server-side (`domain/consent.py::consent_state`) — the client renders this
/// field and never recomputes it from `expiresAt` itself (`docs/engineering.md`:
/// the backend owns every derived value). An unknown value fails to decode
/// rather than being silently dropped.
public enum ConsentState: String, Codable, Sendable, CaseIterable {
    case pending
    case active
    case expiringSoon = "expiring_soon"
    case expired
    case revoked
    case error
}
