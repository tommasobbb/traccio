import Foundation

/// One account's bar on the "Inizio tracciamento" timeline
/// (`docs/design/canvas/TrackingStart.dc.html`), as produced by
/// `trackingTimeline(...)`.
///
/// `startFraction` is where this account's data begins on the shared axis,
/// in `0...1` — the view turns it into a concrete offset at draw time,
/// keeping this type free of any drawing framework (same split as
/// `SpendingBar`). `nil` means the account has no dated movement yet: there
/// is nothing to draw for it.
public struct TrackingTimelineBar: Sendable, Equatable, Identifiable {
    /// The account.
    public let accountID: UUID
    /// Its resolved display name (alias, else provider name, else `nil`).
    public let displayName: String?
    /// The date of its first dated movement, or `nil` when it has none.
    public let earliest: CalendarDate?
    /// Where this account's data starts on the axis, `0...1`. `nil` when
    /// `earliest` is `nil`.
    public let startFraction: Double?
    /// This is the account whose first movement is the latest — the one that
    /// pushes the suggested start forward.
    public let isConstraining: Bool

    public var id: UUID { accountID }

    public init(
        accountID: UUID,
        displayName: String?,
        earliest: CalendarDate?,
        startFraction: Double?,
        isConstraining: Bool
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.earliest = earliest
        self.startFraction = startFraction
        self.isConstraining = isConstraining
    }
}

/// The drawable "Inizio tracciamento" timeline: one bar per account plus the
/// shared axis and the current/suggested threshold, as produced by
/// `trackingTimeline(...)`.
public struct TrackingTimeline: Sendable, Equatable {
    /// One bar per account, in the order the suggestion listed them
    /// (earliest-movement first, accounts with none last).
    public let bars: [TrackingTimelineBar]
    /// The axis' left edge — the earliest account first-movement date — or
    /// `nil` when no account has a dated movement yet.
    public let axisStart: CalendarDate?
    /// The axis' right edge: "now", as passed in.
    public let axisEnd: CalendarDate
    /// Where the current floor (or, absent one, the suggestion) falls on the
    /// axis, `0...1`. `nil` when neither is set.
    public let thresholdFraction: Double?

    public init(
        bars: [TrackingTimelineBar],
        axisStart: CalendarDate?,
        axisEnd: CalendarDate,
        thresholdFraction: Double?
    ) {
        self.bars = bars
        self.axisStart = axisStart
        self.axisEnd = axisEnd
        self.thresholdFraction = thresholdFraction
    }
}

extension TraccioCore {
    /// Build the "Inizio tracciamento" timeline from the per-account
    /// suggestion (ADR 0024), the current floor, and a reference "now".
    ///
    /// Pure axis geometry, not a derivation of any value (`docs/engineering.md`)
    /// — the same "turn a backend breakdown into drawable positions" shape as
    /// `spendingBars(_:)` / `donutSegments(_:)`. The axis runs from the
    /// earliest account first-movement to `now`; each account's
    /// `startFraction` and the `thresholdFraction` are clamped into `0...1`.
    ///
    /// Parameters
    /// ----------
    /// suggestion:
    ///     `GET /settings/tracking-start/suggestion`'s payload.
    /// current:
    ///     The floor currently in effect, or `nil` when none is set.
    /// now:
    ///     Today, as a calendar date — the axis' right edge.
    ///
    /// Returns
    /// -------
    /// A `TrackingTimeline`. `axisStart` is `nil` and every bar's
    /// `startFraction` is `nil` when no account has a dated movement.
    public static func trackingTimeline(
        suggestion: TrackingStartSuggestionResponse,
        current: CalendarDate?,
        now: CalendarDate
    ) -> TrackingTimeline {
        let earliestDates = suggestion.accounts.compactMap(\.earliest)
        let axisStartDate = earliestDates.min()

        let nowSerial = daySerial(now)
        // A year of width when nothing is dated yet, so the axis is never
        // zero-width even though there are no bars to place on it.
        let axisStartSerial = axisStartDate.map { min(daySerial($0), nowSerial) } ?? (nowSerial - 365)
        let span = max(nowSerial - axisStartSerial, 1)

        func fraction(of date: CalendarDate) -> Double {
            min(max((daySerial(date) - axisStartSerial) / span, 0), 1)
        }

        let bars = suggestion.accounts.map { account in
            TrackingTimelineBar(
                accountID: account.accountID,
                displayName: account.displayName,
                earliest: account.earliest,
                startFraction: account.earliest.map(fraction(of:)),
                isConstraining: account.accountID == suggestion.constrainingAccountID
            )
        }

        return TrackingTimeline(
            bars: bars,
            axisStart: axisStartDate,
            axisEnd: now,
            thresholdFraction: (current ?? suggestion.suggestion).map(fraction(of:))
        )
    }

    /// Days from 1970-01-01 for a calendar date — Howard Hinnant's
    /// `days_from_civil`, exact for the proleptic Gregorian calendar. Only
    /// the difference between two of these is used (axis positioning), so the
    /// origin is arbitrary.
    static func daySerial(_ d: CalendarDate) -> Double {
        let y = d.year - (d.month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (d.month + (d.month > 2 ? -3 : 9))
        let doy = (153 * mp + 2) / 5 + d.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Double(era * 146_097 + doe - 719_468)
    }
}
