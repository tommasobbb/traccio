import Foundation

/// Body for `POST /events/{id}` — the single event editor (ADR 0027).
///
/// Mirrors the `UpdateEventRequest` schema in `docs/api/openapi.json`. A
/// **full replace** of the editable fields: `name` is always sent, and each
/// of `emoji` / `color` / `startDate` / `endDate` is sent when set and
/// omitted when `nil` — the backend reads an omitted key as "cleared", so
/// the editor sends whatever its fields currently hold and clearing a value
/// just drops it from the payload. `status` is not here — close/reopen has
/// its own endpoint.
public struct UpdateEventRequest: Encodable, Sendable {
    /// The new name (never cleared by the editor).
    public let name: String
    /// The new emoji, or `nil` to clear.
    public let emoji: String?
    /// The new colour, or `nil` to clear.
    public let color: PaletteColor?
    /// New first day of the range, or `nil` to clear.
    public let startDate: CalendarDate?
    /// New last day of the range, or `nil` to clear.
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
