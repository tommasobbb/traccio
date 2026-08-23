import Foundation

extension TraccioCore {
    /// Format how long ago `date` was, relative to `now` — "4 minutes ago",
    /// "sincronizzato 1 ora fa" once wrapped in a locale-appropriate template.
    ///
    /// Built on `RelativeDateTimeFormatter`, constructed locally rather than
    /// cached in a shared static — the same `Sendable` reasoning as
    /// `iso8601Date(from:)` — and driven entirely by its two `Date` arguments
    /// and `locale`, never the wall clock, so a test can pin both and a
    /// caller controls localization explicitly rather than inheriting
    /// whatever the device happens to be set to.
    ///
    /// Parameters
    /// ----------
    /// date:
    ///     The instant to describe, e.g. a connection's `lastSyncedAt`.
    /// now:
    ///     The reference instant `date` is relative to.
    /// locale:
    ///     Locale for the formatted string. Defaults to `.current`.
    ///
    /// Returns
    /// -------
    /// A short, localized relative-time string.
    public static func relativeTime(from date: Date, to now: Date, locale: Locale = .current)
        -> String
    {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
