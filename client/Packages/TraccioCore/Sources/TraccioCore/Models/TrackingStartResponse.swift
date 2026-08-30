import Foundation

/// The user's current tracking start date (ADR 0024), as returned by
/// `GET /settings` and `POST /settings`.
///
/// Mirrors the `TrackingStartResponse` schema in `docs/api/openapi.json`.
/// `nil` means "no floor — show everything". Raising or clearing the date on
/// the backend never deletes a movement, only hides it.
public struct TrackingStartResponse: Codable, Sendable, Equatable {
    /// The stored floor, or `nil`.
    public let trackingStartDate: CalendarDate?

    private enum CodingKeys: String, CodingKey {
        case trackingStartDate = "tracking_start_date"
    }

    public init(trackingStartDate: CalendarDate?) {
        self.trackingStartDate = trackingStartDate
    }
}
