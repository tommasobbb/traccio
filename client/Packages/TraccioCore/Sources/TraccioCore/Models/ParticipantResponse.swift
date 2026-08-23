/// One person who owes the user back, as returned nested in `AdvanceResponse`.
///
/// Mirrors the `ParticipantSchema` schema in `docs/api/openapi.json`. A free-
/// text name, not a `User` record — enough to answer "who still owes me"
/// without a social graph (see `docs/domain.md`).
public struct ParticipantResponse: Codable, Sendable, Equatable {
    /// The participant's plain name.
    public let name: String
    /// What this participant is expected to pay back, a positive magnitude
    /// in the advance's currency (cents). A reconciliation hint, never
    /// validated against reimbursements.
    public let expectedAmount: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case expectedAmount = "expected_amount"
    }

    public init(name: String, expectedAmount: Int) {
        self.name = name
        self.expectedAmount = expectedAmount
    }
}
