import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.hasUnattributedReimbursements`.
struct AdvanceSummaryTests {
    private func person(currency: String, outstanding: Int) -> PersonSummaryResponse {
        PersonSummaryResponse(
            name: "TEST PERSON", personKey: "test-person", currency: currency,
            expected: outstanding, reimbursed: 0, outstanding: outstanding, advanceCount: 1
        )
    }

    private func total(currency: String, outstanding: Int) -> ReceivableTotalResponse {
        ReceivableTotalResponse(
            currency: currency, outstanding: outstanding, expected: outstanding, reimbursed: 0,
            openAdvances: 1
        )
    }

    @Test func isFalseWhenPerPersonOutstandingMatchesTheTotal() {
        let summary = AdvancesSummaryResponse(
            byPerson: [person(currency: "EUR", outstanding: 1000)],
            totals: [total(currency: "EUR", outstanding: 1000)]
        )
        #expect(TraccioCore.hasUnattributedReimbursements(summary) == false)
    }

    @Test func isTrueWhenTheTotalExceedsThePerPersonSum() {
        let summary = AdvancesSummaryResponse(
            byPerson: [person(currency: "EUR", outstanding: 700)],
            totals: [total(currency: "EUR", outstanding: 1000)]
        )
        #expect(TraccioCore.hasUnattributedReimbursements(summary))
    }

    @Test func isTrueForACurrencyWithNoPersonRowsAtAll() {
        let summary = AdvancesSummaryResponse(
            byPerson: [],
            totals: [total(currency: "USD", outstanding: 500)]
        )
        #expect(TraccioCore.hasUnattributedReimbursements(summary))
    }

    @Test func sumsMultiplePeopleInTheSameCurrencyBeforeComparing() {
        let summary = AdvancesSummaryResponse(
            byPerson: [
                person(currency: "EUR", outstanding: 400),
                person(currency: "EUR", outstanding: 600),
            ],
            totals: [total(currency: "EUR", outstanding: 1000)]
        )
        #expect(TraccioCore.hasUnattributedReimbursements(summary) == false)
    }

    @Test func isFalseForAnEmptySummary() {
        let summary = AdvancesSummaryResponse(byPerson: [], totals: [])
        #expect(TraccioCore.hasUnattributedReimbursements(summary) == false)
    }
}
