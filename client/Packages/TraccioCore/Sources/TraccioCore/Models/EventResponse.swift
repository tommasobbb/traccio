import Foundation

/// One event as returned by `GET /events` or `GET /events/{id}`.
///
/// Mirrors the `EventResponse` schema in `docs/api/openapi.json`. An event is
/// a reporting lens over a set of transactions, not a role: assigning a
/// transaction to one never changes that transaction's `role` or
/// `effectiveAmount` (`docs/domain.md` §Event). `total`/`memberCount` are
/// derived server-side (`domain/events.py::event_total`) from the members'
/// `effectiveAmount`; the client only renders them.
///
/// `startDate`/`endDate` are `CalendarDate`, not `Date` — the backend sends a
/// bare `yyyy-MM-dd` for these, unlike every timestamp field elsewhere in the
/// API.
public struct EventResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier of the event.
    public let id: UUID
    /// The occasion's name, e.g. "Turkey 2026".
    public let name: String
    /// Optional single emoji for the event's tile (ADR 0027). `nil` before
    /// the user picks one.
    public let emoji: String?
    /// Optional colour for the event's tile, from the shared vocabulary
    /// (ADR 0017). `nil` falls back to the neutral default.
    public let color: PaletteColor?
    /// Optional start of the date range — a hint used to suggest membership,
    /// never a rule that assigns it.
    public let startDate: CalendarDate?
    /// Optional end of the date range.
    public let endDate: CalendarDate?
    public let status: EventStatus
    /// How many transactions are grouped under this event.
    public let memberCount: Int
    /// The net total across all members, in minor units (cents). Zero for an
    /// empty event.
    public let total: Int
    /// ISO 4217 code of `total` — the members' shared currency. `nil` for an
    /// empty event, since there is nothing to derive a currency from; never
    /// fabricated.
    public let currency: String?
    /// When the event was created.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case emoji
        case color
        case startDate = "start_date"
        case endDate = "end_date"
        case status
        case memberCount = "member_count"
        case total
        case currency
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        name: String,
        emoji: String? = nil,
        color: PaletteColor? = nil,
        startDate: CalendarDate?,
        endDate: CalendarDate?,
        status: EventStatus,
        memberCount: Int,
        total: Int,
        currency: String?,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.memberCount = memberCount
        self.total = total
        self.currency = currency
        self.createdAt = createdAt
    }
}
