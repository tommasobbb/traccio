import Foundation

/// The result of `AddReimbursementSheet`'s form, bundled as one value.
///
/// Two of its fields (`participantID`, `transactionID`) are both `UUID?` —
/// left as separate closure arguments they would be a footgun a call site
/// could transpose without the compiler ever noticing. One named value
/// instead of a positional tuple makes the mistake impossible to make.
struct ReimbursementDraft {
    /// The amount paid back, a positive magnitude in cents.
    let amount: Int
    /// The participant to attribute this reimbursement to (ADR 0012), or
    /// `nil` to leave it unattributed.
    let participantID: UUID?
    /// The incoming transaction to link, or `nil` for a manual cash entry.
    let transactionID: UUID?
    /// A trimmed note, or `nil` if left blank.
    let note: String?
}
