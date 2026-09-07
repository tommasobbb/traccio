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
    /// Count of still-open advances in this currency.
    public let openAdvances: Int

    private enum CodingKeys: String, CodingKey {
        case currency
        case outstanding
        case openAdvances = "open_advances"
    }

    public init(currency: String, outstanding: Int, openAdvances: Int) {
        self.currency = currency
        self.outstanding = outstanding
        self.openAdvances = openAdvances
    }
}
