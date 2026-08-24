import Foundation

/// One reimbursement as returned by `GET /advances/{id}/reimbursements` or
/// `POST /advances/{id}/reimbursements`.
///
/// Mirrors the `ReimbursementResponse` schema in `docs/api/openapi.json`.
/// Amounts are positive magnitudes in the advance's currency; the advance's
/// derived `reimbursed`/`outstanding`/`status` are not carried here — they
/// live on `AdvanceResponse`, re-fetched via `APIClient.advance(id:)` after a
/// write.
public struct ReimbursementResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier of the reimbursement.
    public let id: UUID
    /// The advance this reimbursement pays back.
    public let advanceID: UUID
    /// The amount paid back, a positive magnitude (cents).
    public let amount: Int
    /// ISO 4217 code of `amount` (the advance's currency).
    public let currency: String
    /// The linked incoming transaction, or `nil` for a manual cash entry.
    public let transactionID: UUID?
    /// The participant this reimbursement is attributed to (ADR 0012), or
    /// `nil` for an unattributed one.
    public let participantID: UUID?
    /// Optional free-text note.
    public let note: String?
    /// When the reimbursement was recorded.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case advanceID = "advance_id"
        case amount
        case currency
        case transactionID = "transaction_id"
        case participantID = "participant_id"
        case note
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        advanceID: UUID,
        amount: Int,
        currency: String,
        transactionID: UUID?,
        participantID: UUID?,
        note: String?,
        createdAt: Date
    ) {
        self.id = id
        self.advanceID = advanceID
        self.amount = amount
        self.currency = currency
        self.transactionID = transactionID
        self.participantID = participantID
        self.note = note
        self.createdAt = createdAt
    }
}
