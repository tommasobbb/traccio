import Foundation

/// One advance as returned by `GET /advances`.
///
/// Mirrors the `AdvanceResponse` schema in `docs/api/openapi.json`. The
/// underlying transaction (`transactionID`) carries `role == .advance`, so
/// its `effectiveAmount` on `GET /transactions` is `ownShare`, not the full
/// amount — the client never recomputes that, just renders both sides.
///
/// `receivable`/`reimbursed`/`outstanding`/`excess` are all positive
/// magnitudes derived server-side (`domain/advances.py::derive_advance`);
/// this type only carries them, it does not fold them together itself.
public struct AdvanceResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier of the advance.
    public let id: UUID
    /// The outgoing transaction this advance is on.
    public let transactionID: UUID
    /// The user's declared share, a positive magnitude (cents).
    public let ownShare: Int
    /// What the user is owed: `|amount| - ownShare`.
    public let receivable: Int
    /// The sum paid back so far.
    public let reimbursed: Int
    /// What is still owed after reimbursements, clamped at zero.
    public let outstanding: Int
    /// Over-reimbursement — flagged rather than silently absorbed. Zero in
    /// the normal case.
    public let excess: Int
    /// ISO 4217 code of every amount above (the transaction's currency).
    public let currency: String
    public let status: AdvanceStatus
    /// People who owe the user back.
    public let participants: [ParticipantResponse]
    /// When the advance was created.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case transactionID = "transaction_id"
        case ownShare = "own_share"
        case receivable
        case reimbursed
        case outstanding
        case excess
        case currency
        case status
        case participants
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        transactionID: UUID,
        ownShare: Int,
        receivable: Int,
        reimbursed: Int,
        outstanding: Int,
        excess: Int,
        currency: String,
        status: AdvanceStatus,
        participants: [ParticipantResponse],
        createdAt: Date
    ) {
        self.id = id
        self.transactionID = transactionID
        self.ownShare = ownShare
        self.receivable = receivable
        self.reimbursed = reimbursed
        self.outstanding = outstanding
        self.excess = excess
        self.currency = currency
        self.status = status
        self.participants = participants
        self.createdAt = createdAt
    }
}
