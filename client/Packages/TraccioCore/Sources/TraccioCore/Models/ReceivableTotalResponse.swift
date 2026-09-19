import Foundation

/// What the user is still owed in one currency, across all advances —
/// carried inside `AdvancesResponse.summary`.
///
/// Mirrors the `ReceivableTotalResponse` schema in `docs/api/openapi.json`.
/// `outstanding` can exceed the sum of the per-person outstandings when some
/// reimbursements aren't attributed to a participant (ADR 0026); the client
/// surfaces both figures rather than hiding the gap.
public struct ReceivableTotalResponse: Codable, Sendable, Equatable, Identifiable {
    /// One entry per currency, so the code is the identity.
    public var id: String { currency }
    /// ISO 4217 code.
    public let currency: String
    /// Total still owed (cents).
    public let outstanding: Int
    /// Total receivable (cents) — the denominator for a "quanto è rientrato"
    /// progress bar across every advance in this currency. Excludes
    /// written-off advances, same as `outstanding`.
    public let expected: Int
    /// Total already paid back (cents) — the numerator for that same bar.
    /// `expected - reimbursed` can diverge from `outstanding` when an advance
    /// is over-reimbursed (neither is clamped at zero, unlike `outstanding`).
    public let reimbursed: Int
    /// Count of still-open advances in this currency.
    public let openAdvances: Int

    private enum CodingKeys: String, CodingKey {
        case currency
        case outstanding
        case expected
        case reimbursed
        case openAdvances = "open_advances"
    }

    public init(currency: String, outstanding: Int, expected: Int, reimbursed: Int, openAdvances: Int) {
        self.currency = currency
        self.outstanding = outstanding
        self.expected = expected
        self.reimbursed = reimbursed
        self.openAdvances = openAdvances
    }
}
