/// Settlement state of a transaction as reported by the bank.
///
/// Mirrors the `TransactionStatus` schema in `docs/api/openapi.json`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as `AccountKind`.
public enum TransactionStatus: String, Codable, Sendable, CaseIterable {
    /// Not yet settled — a card authorization hold or an in-flight transfer.
    case pending
    /// Settled; immutable from this point on.
    case booked
    /// Refused or reversed; immutable, and `effective_amount` is zero
    /// regardless of role.
    case rejected
}
