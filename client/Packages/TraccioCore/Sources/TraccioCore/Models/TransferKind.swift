/// What kind of link a `Transfer` records.
///
/// Mirrors the `TransferKind` schema in `docs/api/openapi.json`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as
/// `TransactionRole`.
public enum TransferKind: String, Codable, Sendable, CaseIterable {
    /// The classic case: money left one account and arrived in another, so the
    /// legs have opposite signs. Both legs become `role == .transfer`.
    case twoSided = "two_sided"
    /// One outflow funds another — a card charge that tops up a wallet so the
    /// wallet can pay a merchant (e.g. PayPal drawing on a Revolut card). Both
    /// legs are outflows; only the funding leg becomes `role == .funding`
    /// (zeroed), the funded leg stays `.personal` and is the real expense.
    case fundedPayment = "funded_payment"
}
