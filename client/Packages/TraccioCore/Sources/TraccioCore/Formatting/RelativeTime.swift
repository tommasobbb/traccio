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

    /// The abbreviated sibling of `relativeTime(from:to:locale:)` — "3 h fa"/
    /// "tra 1 h" instead of "3 ore fa"/"tra 1 ora".
    ///
    /// For a status line sharing a single line with other text (Conti's
    /// connection status, `docs/design/tokens.md`'s "Text never wraps"),
    /// where `.full`'s extra length is exactly what forces a wrap.
    ///
    /// Parameters
    /// ----------
    /// date, now, locale
    ///     Same as `relativeTime(from:to:locale:)`.
    ///
    /// Returns
    /// -------
    /// A short, abbreviated, localized relative-time string.
    public static func relativeTimeShort(from date: Date, to now: Date, locale: Locale = .current)
        -> String
    {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
