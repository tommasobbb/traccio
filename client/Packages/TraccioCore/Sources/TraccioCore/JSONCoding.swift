import Foundation

extension TraccioCore {
    /// A `JSONDecoder` configured to decode backend responses.
    ///
    /// The backend (FastAPI/Pydantic) serialises timestamps as ISO 8601, but
    /// the exact shape varies: fractional seconds may be present or absent, and
    /// a timezone offset may be present (aware) or absent (naive, assumed UTC).
    /// `JSONDecoder`'s built-in `.iso8601` strategy rejects several of these,
    /// so this uses a `.custom` strategy that tries each accepted shape in turn.
    ///
    /// - Returns: A decoder ready to decode the TraccioCore response models.
    public static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = iso8601Date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognised ISO 8601 date-time"
                )
            }
            return date
        }
        return decoder
    }

    /// Parse an ISO 8601 date-time string in any of the shapes the backend emits.
    ///
    /// Formatters are built locally rather than cached in a shared static:
    /// under Swift's strict concurrency a mutable global formatter is not
    /// `Sendable`, and decoding is not hot enough for the cost to matter.
    /// Ordered most specific first — timezone-aware shapes via
    /// `ISO8601DateFormatter`, offset-less shapes via a UTC `DateFormatter`.
    ///
    /// - Parameter raw: The string value from the JSON payload.
    /// - Returns: The parsed `Date`, or `nil` if no accepted format matched.
    static func iso8601Date(from raw: String) -> Date? {
        let awareWithFraction = ISO8601DateFormatter()
        awareWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = awareWithFraction.date(from: raw) { return date }

        let aware = ISO8601DateFormatter()
        aware.formatOptions = [.withInternetDateTime]
        if let date = aware.date(from: raw) { return date }

        if let date = utcDateFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSSSS").date(from: raw) {
            return date
        }
        return utcDateFormatter("yyyy-MM-dd'T'HH:mm:ss").date(from: raw)
    }

    /// A fixed-format `DateFormatter` pinned to UTC and the POSIX locale, for
    /// naive (offset-less) timestamps.
    private static func utcDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
