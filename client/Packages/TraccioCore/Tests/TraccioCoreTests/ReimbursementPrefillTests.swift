import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.reimbursementAmountInput(forLinked:)` — the string
/// that seeds `AddReimbursementSheet`'s amount field when a movement is
/// linked. Fixtures are synthetic (`docs/engineering.md`).
struct ReimbursementPrefillTests {
    private static func makeTransaction(amount: Int) -> TransactionResponse {
        TransactionResponse(
            id: UUID(),
            accountID: UUID(),
            amount: amount,
            effectiveAmount: amount,
            currency: "EUR",
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: .booked,
            role: .personal,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil,
            eventID: nil
        )
    }

    @Test func emptyForNoSelection() {
        #expect(TraccioCore.reimbursementAmountInput(forLinked: nil).isEmpty)
    }

    @Test func magnitudeOfAnIncomingMovement() {
        #expect(
            TraccioCore.reimbursementAmountInput(forLinked: Self.makeTransaction(amount: 4200))
                == "42,00"
        )
    }

    @Test func padsTheCentsToTwoDigits() {
        #expect(
            TraccioCore.reimbursementAmountInput(forLinked: Self.makeTransaction(amount: 205))
                == "2,05"
        )
    }

    @Test func handlesAmountsAboveOneThousandWithoutGrouping() {
        #expect(
            TraccioCore.reimbursementAmountInput(forLinked: Self.makeTransaction(amount: 10156))
                == "101,56"
        )
    }

    @Test func takesTheMagnitudeOfANegativeAmountDefensively() {
        #expect(
            TraccioCore.reimbursementAmountInput(forLinked: Self.makeTransaction(amount: -4200))
                == "42,00"
        )
    }

    @Test func roundTripsThroughParseMoneyInput() {
        let text = TraccioCore.reimbursementAmountInput(
            forLinked: Self.makeTransaction(amount: 7391)
        )
        #expect(TraccioCore.parseMoneyInput(text) == 7391)
    }
}
