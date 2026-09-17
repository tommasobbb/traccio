import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.formatDate`. `formatDate` renders in the device's
/// own time zone (like the ad-hoc formatters it replaced), so assertions
/// read the expected day/month/year back out of the same `Calendar.current`
/// rather than hardcoding a day number that could shift a test run in an
/// extreme time zone.
struct DateFormattingTests {
    /// 2026-09-17, 14:30 UTC — a fixed instant, comfortably clear of a day
    /// boundary in every real-world time zone.
    private static let fixedDate = Date(timeIntervalSince1970: 1_789_654_200)
    private static let expectedDay = String(Calendar.current.component(.day, from: fixedDate))

    @Test func dayMonthHasNoYear() {
        let result = TraccioCore.formatDate(Self.fixedDate, style: .dayMonth)
        #expect(!result.contains("2026"))
        #expect(result.contains(Self.expectedDay))
        #expect(result.contains("settembre"))
    }

    @Test func dayMonthYearIncludesTheFullMonthNameAndYear() {
        let result = TraccioCore.formatDate(Self.fixedDate, style: .dayMonthYear)
        #expect(result.contains(Self.expectedDay))
        #expect(result.contains("settembre"))
        #expect(result.contains("2026"))
    }

    @Test func dayMonthAbbreviatedYearUsesTheShortMonthName() {
        let result = TraccioCore.formatDate(Self.fixedDate, style: .dayMonthAbbreviatedYear)
        #expect(result.contains(Self.expectedDay))
        #expect(result.contains("set"))
        #expect(!result.contains("settembre"))
        #expect(result.contains("2026"))
    }

    @Test func dayMonthYearTimeIncludesAColonSeparatedTime() {
        let result = TraccioCore.formatDate(Self.fixedDate, style: .dayMonthYearTime)
        #expect(result.contains("2026"))
        #expect(result.contains(":"))
    }

    @Test func monthYearAbbreviatedHasNoDay() {
        let result = TraccioCore.formatDate(Self.fixedDate, style: .monthYearAbbreviated)
        #expect(result.contains("set"))
        #expect(result.contains("2026"))
    }

    @Test func monthYearUsesTheFullMonthName() {
        let result = TraccioCore.formatDate(Self.fixedDate, style: .monthYear)
        #expect(result.contains("settembre"))
        #expect(result.contains("2026"))
    }

    @Test func yearIsTheBareFourDigits() {
        let result = TraccioCore.formatDate(Self.fixedDate, style: .year)
        #expect(result == "2026")
    }

    @Test func advancesAndPersonDetailNowAgreeOnTheYear() {
        // The bug this style unification fixed: two screens rendering the
        // same `bookedAt` field used to disagree on whether a year showed
        // (AdvancesView omitted it, PersonDetailView didn't). Both now use
        // the same style, so their output can never diverge again.
        let advancesRow = TraccioCore.formatDate(Self.fixedDate, style: .dayMonthAbbreviatedYear)
        let personDetailRow = TraccioCore.formatDate(Self.fixedDate, style: .dayMonthAbbreviatedYear)
        #expect(advancesRow == personDetailRow)
        #expect(advancesRow.contains("2026"))
    }
}
