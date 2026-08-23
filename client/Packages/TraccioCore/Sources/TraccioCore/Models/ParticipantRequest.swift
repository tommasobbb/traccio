/// One participant on the wire for `POST /advances`.
///
/// Mirrors the `ParticipantSchema` schema in `docs/api/openapi.json`. Kept
/// separate from `ParticipantResponse` despite an identical wire shape — same
/// reasoning as `ConfirmTransferRequest`/`RejectTransferRequest`: an
/// independent rename on either side stays a compile error instead of a
/// silent mismatch.
public struct ParticipantRequest: Encodable, Sendable, Equatable {
    /// The participant's plain name.
    public let name: String
    /// What this participant is expected to pay back, a positive magnitude
    /// in the advance's currency (cents).
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
