import Foundation

/// One person's receivable rolled up across every advance they appear on,
/// carried inside `AdvancesResponse.summary`.
///
/// Mirrors the `PersonSummaryResponse` schema in `docs/api/openapi.json`.
/// There is no person entity server-side (ADR 0026): names are matched
/// case- and whitespace-insensitively, so `"Marco"` and `" marco "` roll up
/// together but a genuine typo does not. Every amount is a positive magnitude
/// in `currency`, derived server-side — the client only renders it.
public struct PersonSummaryResponse: Codable, Sendable, Equatable, Identifiable {
    /// Stable within one response: the server already emits one row per
    /// `(folded name, currency)`, and `name` here is that row's first-seen
    /// spelling with whitespace collapsed, so this is unique. Not a server
    /// id — there is no person entity — just a key for a SwiftUI `ForEach`.
    public var id: String { "\(name.lowercased())|\(currency)" }
    /// Display spelling — the first one seen for this person.
    public let name: String
    /// ISO 4217 code of every amount here.
    public let currency: String
    /// Sum of this person's expected repayments (cents).
    public let expected: Int
    /// Sum attributed back to this person (cents).
    public let reimbursed: Int
    /// What this person still owes in total (cents), each advance clamped at
    /// zero before summing.
    public let outstanding: Int
    /// How many advances this person appears on.
    public let advanceCount: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case currency
        case expected
        case reimbursed
        case outstanding
        case advanceCount = "advance_count"
    }

    public init(
        name: String,
        currency: String,
        expected: Int,
        reimbursed: Int,
        outstanding: Int,
        advanceCount: Int
    ) {
        self.name = name
        self.currency = currency
        self.expected = expected
        self.reimbursed = reimbursed
        self.outstanding = outstanding
        self.advanceCount = advanceCount
    }
}
