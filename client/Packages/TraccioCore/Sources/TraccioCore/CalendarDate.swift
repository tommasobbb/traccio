import Foundation

/// A calendar date with no time component or time zone — `year`/`month`/`day`.
///
/// The backend's `date`-typed fields (`EventResponse.start_date`/`end_date`)
/// serialise as a bare `"2026-08-01"`, unlike every other timestamp field in
/// the API, which is a full ISO 8601 date-*time* decoded via
/// `TraccioCore.jsonDecoder()`'s `.custom` strategy (`JSONCoding.swift`). That
/// strategy deliberately does not accept a date-only string: a calendar date
/// is not an instant, and picking an implicit time (midnight? noon? which
/// zone?) to force it into a `Date` would be a fabrication. This type carries
/// the three components as-is instead.
public struct CalendarDate: Codable, Sendable, Equatable, Comparable, Hashable {
    /// The four-digit year.
    public let year: Int
    /// The month, 1–12.
    public let month: Int
    /// The day of month, 1–31 (not validated against the month's length —
    /// the backend is the source of truth for validity).
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Extract the calendar date from a `Date` — the counterpart a
    /// `DatePicker` result needs, since `DatePicker` only produces `Date`.
    /// Built locally rather than a shared static, the same `Sendable`
    /// reasoning as `TraccioCore.iso8601Date(from:)`.
    ///
    /// - Parameters:
    ///   - date: The instant to read year/month/day from.
    ///   - calendar: The calendar to interpret `date` in. Defaults to
    ///     `.iso8601` (UTC-aligned, matching the wire format), not the
    ///     device's current calendar/time zone — a date picked in a
    ///     `DatePicker` should not shift by a day depending on where the
    ///     device happens to be.
    public init(date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) {
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = utcCalendar.dateComponents([.year, .month, .day], from: date)
        self.year = components.year ?? 1
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = CalendarDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a yyyy-MM-dd calendar date, got \"\(raw)\""
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    /// The `yyyy-MM-dd` wire representation, zero-padded.
    public var wireValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Reconstruct a `Date` at local midnight for this calendar date, in
    /// `calendar` — the counterpart to `init(date:calendar:)`, needed
    /// wherever a calendar date must round-trip back into an instant (e.g. a
    /// dashboard bucket boundary becoming a `TransactionFilter.start`/`.end`
    /// for a drill-through).
    ///
    /// Defaults to `.current` (the device's own calendar/time zone), not
    /// `.iso8601`/UTC like `init(date:calendar:)`'s default — a dashboard
    /// bucket is computed in the device's local time zone
    /// (`GET /dashboard/summary`'s `tz` parameter), so reconstructing its
    /// boundary must use that same zone, not UTC.
    ///
    /// - Parameter calendar: The calendar to interpret this date in.
    /// - Returns: The instant, or `nil` if `year`/`month`/`day` do not form a
    ///   valid date in `calendar` (e.g. a malformed `day` value the backend
    ///   never actually sends).
    public func date(calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Parse a strict `yyyy-MM-dd` string, rejecting anything else — in
    /// particular a full date-*time* string, which must not silently decode
    /// as a calendar date and drop its time component.
    ///
    /// - Parameter raw: The candidate string.
    /// - Returns: The parsed value, or `nil` if `raw` is not exactly
    ///   `yyyy-MM-dd`.
    private static func parse(_ raw: String) -> CalendarDate? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return CalendarDate(year: year, month: month, day: day)
    }
}
