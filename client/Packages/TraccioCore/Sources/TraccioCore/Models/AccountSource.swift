/// Where an account comes from — bank-synced or user-maintained.
///
/// Mirrors the `AccountSource` schema in `docs/api/openapi.json`. Derived
/// server-side from `connection_id` (ADR 0020), never stored; the client
/// renders it rather than inferring it from a `nil` `connectionID`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as `AccountKind`.
public enum AccountSource: String, Codable, Sendable, CaseIterable {
    /// Backed by a bank connection; its transactions are provider-sourced and
    /// immutable.
    case synced
    /// User-created and hand-maintained (a cash float, an investment
    /// pass-through); its transactions are user-entered, editable, and
    /// deletable, and a sync never touches it.
    case manual
}
