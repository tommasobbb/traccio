/// Envelope for the reimbursement list returned by
/// `GET /advances/{id}/reimbursements`.
///
/// Mirrors the `ReimbursementsResponse` schema in `docs/api/openapi.json`. A
/// wrapper object rather than a bare array leaves room for metadata later
/// without breaking decoding — same reasoning as `AdvancesResponse`.
public struct ReimbursementsResponse: Codable, Sendable {
    /// The advance's reimbursements, oldest first.
    public let reimbursements: [ReimbursementResponse]

    public init(reimbursements: [ReimbursementResponse]) {
        self.reimbursements = reimbursements
    }
}
