/// Lifecycle state of an advance.
///
/// Mirrors the `AdvanceStatus` schema in `docs/api/openapi.json`. The raw
/// values match the wire format exactly, so an unknown value fails to decode
/// rather than being silently dropped — the same discipline as `AccountKind`.
public enum AdvanceStatus: String, Codable, Sendable, CaseIterable {
    /// The user is still owed money; the default when an advance is created.
    case open
    /// Fully paid back — reimbursements cover the receivable.
    case settled
    /// Given up on: the outstanding amount was folded into the user's
    /// spending instead.
    case writtenOff = "written_off"
}
