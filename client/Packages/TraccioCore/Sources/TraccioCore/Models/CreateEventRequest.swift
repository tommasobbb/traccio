import Foundation

/// Body for `POST /events`.
///
/// Mirrors the `CreateEventRequest` schema in `docs/api/openapi.json`.
/// `CodingKeys` spell the wire name explicitly, following every other request
/// model's convention (`ConfirmCategoryRequest`, `CreateRuleRequest`).
public struct CreateEventRequest: Encodable, Sendable {
    /// The occasion's name.
    public let name: String
    /// Optional single emoji for the event's tile (ADR 0027). Omitted from the
    /// payload when `nil`, which the backend reads as "not set".
    public let emoji: String?
    /// Optional colour for the event's tile. Omitted when `nil`.
    public let color: PaletteColor?
    /// Optional start of the date range.
    public let startDate: CalendarDate?
    /// Optional end of the date range.
    public let endDate: CalendarDate?

    private enum CodingKeys: String, CodingKey {
        case name
        case emoji
        case color
        case startDate = "start_date"
        case endDate = "end_date"
    }

    public init(
        name: String,
        emoji: String? = nil,
        color: PaletteColor? = nil,
        startDate: CalendarDate? = nil,
        endDate: CalendarDate? = nil
    ) {
        self.name = name
        self.emoji = emoji
        self.color = color
        self.startDate = startDate
        self.endDate = endDate
    }
}
