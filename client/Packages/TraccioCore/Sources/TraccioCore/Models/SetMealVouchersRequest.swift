import Foundation

/// Body for `POST /settings/meal-vouchers` (ADR 0029).
///
/// Mirrors the `SetMealVouchersRequest` schema in `docs/api/openapi.json`.
/// A separate endpoint (and model) from `SetTrackingStartRequest` rather
/// than a second field on it — that body is deliberately
/// mandatory-but-nullable so "clear the date" is never ambiguous with
/// "leave it alone", and a plain optional boolean on the same body would
/// reintroduce exactly that ambiguity for this setting.
public struct SetMealVouchersRequest: Encodable, Sendable {
    /// The new state.
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}
