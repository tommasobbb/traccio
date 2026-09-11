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
    /// A currency-agnostic wallet (e.g. PayPal). It has no single account
    /// currency; the per-transaction currency is authoritative.
    case wallet
    /// A hand-tracked cash float (e.g. "Contanti"). Only ever a manual
    /// account — there is no bank feed for cash (ADR 0020).
    case cash
    /// A meal-voucher / benefit balance (e.g. a Satispay "Buoni Pasto"
    /// account, ADR 0023). Only ever a manual account, same reasoning as
    /// `.cash`. When the user's meal-vouchers setting is on (ADR 0029), a
    /// voucher-kind account's spending is broken out of the dashboard's
    /// headline totals instead of being folded into them.
    case voucher
}
