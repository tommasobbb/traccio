/// Lifecycle state of a bank connection's consent, as last reported by the
/// provider.
///
/// Mirrors the `ConnectionStatus` schema in `docs/api/openapi.json`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as `AccountKind`.
/// See `ConsentState` for the field the client should actually render: this
/// one alone does not account for `expires_at` elapsing.
public enum ConnectionStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case active
    case expired
    case revoked
    case error
}
