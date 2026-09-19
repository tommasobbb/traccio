import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.groupByDay(_:calendar:)` — pure grouping logic, no
/// backend involved. Fixtures are synthetic round amounts and invented
/// merchants (`docs/engineering.md`).
struct TransactionDayGroupTests {
    private static let calendar = Calendar(identifier: .gregorian)

    /// Build a minimal transaction with the given effective date, so each
    /// test only spells out what it actually varies.
    private static func transaction(
        id: UUID = UUID(),
        bookedAt: Date? = nil,
        valueDate: Date? = nil
    ) -> TransactionResponse {
        TransactionResponse(
            id: id,
            accountID: UUID(),
            amount: -1000,
            effectiveAmount: -1000,
            currency: "EUR",
            bookedAt: bookedAt,
            valueDate: valueDate,
            description: "TEST MERCHANT",
            displayDescription: nil,
            status: .booked,
            role: .personal,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil,
            eventID: nil
        )
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        guard let result = calendar.date(from: components) else {
            preconditionFailure("invalid test date components")
        }
        return result
    }

    @Test func collapsesConsecutiveSameDayTransactions() {
        let first = Self.transaction(bookedAt: Self.date(2026, 8, 20, hour: 9))
        let second = Self.transaction(bookedAt: Self.date(2026, 8, 20, hour: 18))
        let groups = TraccioCore.groupByDay([first, second], calendar: Self.calendar)

        #expect(groups.count == 1)
        #expect(groups[0].transactions.count == 2)
        #expect(groups[0].transactions[0].id == first.id)
        #expect(groups[0].transactions[1].id == second.id)
    }

    @Test func splitsOnADayBoundary() {
        let day1 = Self.transaction(bookedAt: Self.date(2026, 8, 20))
        let day2 = Self.transaction(bookedAt: Self.date(2026, 8, 19))
        let groups = TraccioCore.groupByDay([day1, day2], calendar: Self.calendar)

        #expect(groups.count == 2)
        #expect(groups[0].day == Self.calendar.startOfDay(for: Self.date(2026, 8, 20)))
        #expect(groups[1].day == Self.calendar.startOfDay(for: Self.date(2026, 8, 19)))
    }

    @Test func fallsBackToValueDateWhenNotBooked() {
        let pending = Self.transaction(bookedAt: nil, valueDate: Self.date(2026, 8, 18))
        let groups = TraccioCore.groupByDay([pending], calendar: Self.calendar)

        #expect(groups.count == 1)
        #expect(groups[0].day == Self.calendar.startOfDay(for: Self.date(2026, 8, 18)))
    }

    @Test func groupsUndatedTransactionsInATrailingGroup() {
        let dated = Self.transaction(bookedAt: Self.date(2026, 8, 20))
        let undatedA = Self.transaction(bookedAt: nil, valueDate: nil)
        let undatedB = Self.transaction(bookedAt: nil, valueDate: nil)
        let groups = TraccioCore.groupByDay([dated, undatedA, undatedB], calendar: Self.calendar)

        #expect(groups.count == 2)
        #expect(groups[0].day != nil)
        #expect(groups[1].day == nil)
        #expect(groups[1].transactions.count == 2)
    }

    @Test func returnsNoGroupsForEmptyInput() {
        let groups = TraccioCore.groupByDay([], calendar: Self.calendar)
        #expect(groups.isEmpty)
    }
}
