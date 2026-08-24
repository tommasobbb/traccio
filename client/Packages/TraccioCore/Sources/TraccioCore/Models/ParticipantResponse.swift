import Foundation

/// One person who owes the user back, as returned nested in `AdvanceResponse`.
///
/// Mirrors the `ParticipantResponse` schema in `docs/api/openapi.json`. A
/// free-text name, not a `User` record — enough to answer "who still owes
/// me" without a social graph (see `docs/domain.md`).
///
/// Carries an `id` and a derived reimbursement state (ADR 0012) that
/// `ParticipantRequest` (the write side) does not: the id doesn't exist yet
/// at creation time, and there is nothing to derive over zero reimbursements.
/// The `id` is what `CreateReimbursementRequest.participantID` attributes a
/// reimbursement to, and is stable across every subsequent read — see
/// `AdvancesViewModelTests`/`TransactionDetailViewModelTests` for the
/// round-trip this replaced a `ForEach(..., id: \.offset)` workaround with.
public struct ParticipantResponse: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier of the participant.
    public let id: UUID
    /// The participant's plain name.
    public let name: String
    /// What this participant is expected to pay back, a positive magnitude
    /// in the advance's currency (cents). A reconciliation hint, never
    /// validated against reimbursements.
    public let expectedAmount: Int
    /// The sum of reimbursements attributed to this participant, a positive
    /// magnitude.
    public let reimbursed: Int
    /// What this participant still owes, clamped at zero.
    public let outstanding: Int
    /// Over-reimbursement for this participant specifically, clamped at
    /// zero — flagged, not absorbed, same as the advance-level `excess`.
    public let excess: Int
    /// `settled` once this participant's reimbursements cover their
    /// `expectedAmount`, else `outstanding`.
    public let status: ParticipantStatus

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case expectedAmount = "expected_amount"
        case reimbursed
        case outstanding
        case excess
        case status
    }

    public init(
        id: UUID,
        name: String,
        expectedAmount: Int,
        reimbursed: Int,
        outstanding: Int,
        excess: Int,
        status: ParticipantStatus
    ) {
        self.id = id
        self.name = name
        self.expectedAmount = expectedAmount
        self.reimbursed = reimbursed
        self.outstanding = outstanding
        self.excess = excess
        self.status = status
    }
}
