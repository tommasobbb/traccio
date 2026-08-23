import Foundation

/// Body for `POST /advances`.
///
/// Mirrors the `CreateAdvanceRequest` schema in `docs/api/openapi.json`.
/// `CodingKeys` spell the wire name explicitly, following every other
/// request model's convention (`ConfirmCategoryRequest`,
/// `ConfirmTransferRequest`) rather than leaning on an encoder-wide
/// case-conversion strategy.
public struct CreateAdvanceRequest: Encodable, Sendable {
    /// The outgoing transaction to mark as an advance. Must be the caller's,
    /// a `personal` non-`rejected` spend.
    public let transactionID: UUID
    /// The part of the advance the user actually owes, a positive magnitude
    /// in the transaction's currency; `0 <= ownShare <= |amount|`, enforced
    /// server-side — the client never validates this range itself.
    public let ownShare: Int
    /// People who owe the user back; may be empty.
    public let participants: [ParticipantRequest]

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case ownShare = "own_share"
        case participants
    }

    public init(transactionID: UUID, ownShare: Int, participants: [ParticipantRequest] = []) {
        self.transactionID = transactionID
        self.ownShare = ownShare
        self.participants = participants
    }
}
