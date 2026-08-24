/// Derived reimbursement status of one participant (ADR 0012).
///
/// Mirrors the `ParticipantStatus` schema in `docs/api/openapi.json`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as `AdvanceStatus`.
public enum ParticipantStatus: String, Codable, Sendable, CaseIterable {
    /// Reimbursed less than their expected share so far (or not attributed
    /// any reimbursement at all).
    case outstanding
    /// Reimbursed at least their expected share — an exact match or an
    /// overpayment both count.
    case settled
}
