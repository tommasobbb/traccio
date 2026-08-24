import Foundation

/// Body for `POST /advances/{id}/reimbursements`.
///
/// Mirrors the `CreateReimbursementRequest` schema in
/// `docs/api/openapi.json`. `CodingKeys` spell the wire name explicitly,
/// following every other request model's convention.
public struct CreateReimbursementRequest: Encodable, Sendable {
    /// The amount paid back, a positive magnitude in the advance's currency
    /// (cents); must be `> 0`.
    public let amount: Int
    /// The incoming transaction to link (the caller's, a `personal`
    /// non-`rejected` credit). `nil` for a manual cash reimbursement.
    public let transactionID: UUID?
    /// The participant to attribute this reimbursement to (ADR 0012). Must be
    /// one of the advance's own participants, or the backend rejects it with
    /// a `404 unknown_participant`. `nil` to leave it unattributed.
    public let participantID: UUID?
    /// Optional free-text note.
    public let note: String?

    private enum CodingKeys: String, CodingKey {
        case amount
        case transactionID = "transaction_id"
        case participantID = "participant_id"
        case note
    }

    public init(
        amount: Int, transactionID: UUID? = nil, participantID: UUID? = nil, note: String? = nil
    ) {
        self.amount = amount
        self.transactionID = transactionID
        self.participantID = participantID
        self.note = note
    }
}
