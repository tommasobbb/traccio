import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TransactionResponse.effectiveDate` — the `coalesce(booked_at,
/// value_date)` mirror the day-grouping screen relies on. `TransactionDayGroupTests`
/// exercises the same fallback indirectly through `groupByDay`; these pin the
/// property itself. Fixtures are synthetic round amounts and an invented
/// merchant (`docs/engineering.md`).
struct TransactionResponseEffectiveDateTests {
    private static func transaction(bookedAt: Date?, valueDate: Date?) -> TransactionResponse {
        TransactionResponse(
            id: UUID(),
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

    @Test func prefersBookedAtWhenBothArePresent() {
        let booked = Date(timeIntervalSince1970: 1_789_654_200)
        let value = Date(timeIntervalSince1970: 1_789_000_000)
        let transaction = Self.transaction(bookedAt: booked, valueDate: value)
        #expect(transaction.effectiveDate == booked)
    }

    @Test func fallsBackToValueDateWhenNotBooked() {
        let value = Date(timeIntervalSince1970: 1_789_000_000)
        let transaction = Self.transaction(bookedAt: nil, valueDate: value)
        #expect(transaction.effectiveDate == value)
    }

    @Test func isNilWhenNeitherDateIsSet() {
        let transaction = Self.transaction(bookedAt: nil, valueDate: nil)
        #expect(transaction.effectiveDate == nil)
    }
}
