import Foundation

/// The user's current settings (ADR 0024, ADR 0029), as returned by
/// `GET /settings` and `POST /settings`.
///
/// Mirrors the `SettingsResponse` schema in `docs/api/openapi.json`.
public struct SettingsResponse: Codable, Sendable, Equatable {
    /// The stored tracking-start floor (ADR 0024), or `nil` — "no floor,
    /// show everything". Raising or clearing the date on the backend never
    /// deletes a movement, only hides it.
    public let trackingStartDate: CalendarDate?
    /// Whether the dashboard's "Buoni pasto" breakout is on (ADR 0029).
    public let mealVouchersEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case trackingStartDate = "tracking_start_date"
        case mealVouchersEnabled = "meal_vouchers_enabled"
    }

    public init(trackingStartDate: CalendarDate?, mealVouchersEnabled: Bool) {
        self.trackingStartDate = trackingStartDate
        self.mealVouchersEnabled = mealVouchersEnabled
    }
}
