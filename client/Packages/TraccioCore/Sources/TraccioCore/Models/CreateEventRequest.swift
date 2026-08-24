import Foundation

/// Body for `POST /events`.
///
/// Mirrors the `CreateEventRequest` schema in `docs/api/openapi.json`.
/// `CodingKeys` spell the wire name explicitly, following every other request
/// model's convention (`ConfirmCategoryRequest`, `CreateRuleRequest`).
public struct CreateEventRequest: Encodable, Sendable {
    /// The occasion's name.
    public let name: String
    /// Optional start of the date range.
    public let startDate: CalendarDate?
    /// Optional end of the date range.
    public let endDate: CalendarDate?

    private enum CodingKeys: String, CodingKey {
        case name
        case startDate = "start_date"
        case endDate = "end_date"
    }

    public init(name: String, startDate: CalendarDate? = nil, endDate: CalendarDate? = nil) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
    }
}
