import Foundation

/// Body for `POST /settings` (ADR 0024).
///
/// Mirrors the `SetTrackingStartRequest` schema in `docs/api/openapi.json`.
/// `tracking_start_date` is **mandatory but nullable**: the key must be
/// present so "clear it" (`null`) is never ambiguous with "leave it alone"
/// (key omitted). Swift's synthesized `Encodable` uses `encodeIfPresent` for
/// an `Optional` and would drop the key on `nil`, so `encode(to:)` is written
/// by hand — the same reason `SetCategoryAppearanceRequest` needs one.
public struct SetTrackingStartRequest: Encodable, Sendable {
    /// The new floor, or `nil` to clear it.
    public let trackingStartDate: CalendarDate?

    public init(trackingStartDate: CalendarDate?) {
        self.trackingStartDate = trackingStartDate
    }

    private enum CodingKeys: String, CodingKey {
        case trackingStartDate = "tracking_start_date"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `encode`, not `encodeIfPresent` — emits an explicit `null` on `nil`.
        try container.encode(trackingStartDate, forKey: .trackingStartDate)
    }
}
