import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.canBecomeAdvance(_:)`. Fixtures are synthetic
/// (`.claude/rules/data-safety.md`): invented ids, round amounts.
struct AdvanceEligibilityTests {
    private static func makeTransaction(
        amount: Int = -1000,
        status: TransactionStatus = .booked,
        role: TransactionRole = .personal
    ) -> TransactionResponse {
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
            status: status,
            role: role,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil
        )
    }

    @Test func trueForAPersonalOutgoingBookedTransaction() {
        #expect(TraccioCore.canBecomeAdvance(Self.makeTransaction()))
    }

    @Test func trueForAPendingOutgoingTransaction() {
        // Pending is not one of `validate_advance`'s exclusions — only
        // `rejected` is.
        #expect(TraccioCore.canBecomeAdvance(Self.makeTransaction(status: .pending)))
    }

    @Test func falseForAnIncomingTransaction() {
        #expect(!TraccioCore.canBecomeAdvance(Self.makeTransaction(amount: 1000)))
    }

    @Test func falseForARejectedTransaction() {
        #expect(!TraccioCore.canBecomeAdvance(Self.makeTransaction(status: .rejected)))
    }

    @Test func falseWhenAlreadyAnAdvance() {
        #expect(!TraccioCore.canBecomeAdvance(Self.makeTransaction(role: .advance)))
    }

    @Test func falseWhenAlreadyATransferOrReimbursement() {
        #expect(!TraccioCore.canBecomeAdvance(Self.makeTransaction(role: .transfer)))
        #expect(!TraccioCore.canBecomeAdvance(Self.makeTransaction(role: .reimbursement)))
    }
}
