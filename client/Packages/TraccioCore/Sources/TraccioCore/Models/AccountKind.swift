/// Kind of balance-bearing account exposed by a bank.
///
/// Mirrors the `AccountKind` schema in `docs/api/openapi.json`. The raw values
/// match the wire format exactly, so an unknown value fails to decode rather
/// than being silently dropped.
public enum AccountKind: String, Codable, Sendable, CaseIterable {
    /// A current (checking) account.
    case current
    /// A savings account.
    case savings
    /// A card account. Many banks invert the sign convention here; the backend
    /// adapter normalizes it (see `docs/domain.md`).
    case card
}
