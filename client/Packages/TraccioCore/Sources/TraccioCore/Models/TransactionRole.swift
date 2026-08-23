/// How much of a transaction counts as personal spending.
///
/// Mirrors the `TransactionRole` schema in `docs/api/openapi.json`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as `AccountKind`.
public enum TransactionRole: String, Codable, Sendable, CaseIterable {
    /// A normal movement; `effective_amount` is the full `amount`.
    case personal
    /// One leg of a transfer between the user's own accounts;
    /// `effective_amount` is zero.
    case transfer
    /// Money laid out on someone else's behalf; `effective_amount` is the
    /// user's own declared share, not the full amount.
    case advance
    /// Money coming back for an advance; `effective_amount` is zero.
    case reimbursement
}
