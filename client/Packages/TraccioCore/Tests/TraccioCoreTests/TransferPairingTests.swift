import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.canLinkAsTransfer(_:_:)` — the client-side gate for
/// which two rows may be linked as a transfer. Mirrors
/// `validate_transfer_pair` on the fields present on `TransactionResponse`.
/// Fixtures are synthetic (`.claude/rules/data-safety.md`).
struct TransferPairingTests {
    private static let accountA = UUID()
    private static let accountB = UUID()

    private static func makeTransaction(
        accountID: UUID = accountA,
        amount: Int = -5000,
        currency: String = "EUR",
        status: TransactionStatus = .booked,
        role: TransactionRole = .personal
    ) -> TransactionResponse {
        TransactionResponse(
            id: UUID(),
            accountID: accountID,
            amount: amount,
            effectiveAmount: amount,
            currency: currency,
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: status,
            role: role,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil,
            eventID: nil
        )
    }

    /// A valid pair: opposite signs, same currency, different accounts, both
    /// personal and booked, non-zero — order does not matter.
    private static func validOutgoing() -> TransactionResponse {
        makeTransaction(accountID: accountA, amount: -5000)
    }

    private static func validIncoming() -> TransactionResponse {
        makeTransaction(accountID: accountB, amount: 5000)
    }

    @Test func trueForAStructurallyValidPair() {
        #expect(TraccioCore.canLinkAsTransfer(Self.validOutgoing(), Self.validIncoming()))
    }

    @Test func symmetricInItsArguments() {
        #expect(TraccioCore.canLinkAsTransfer(Self.validIncoming(), Self.validOutgoing()))
    }

    @Test func toleranceAndWindowAreNotReproduced() {
        // Wildly different magnitudes are fine for an explicit link — the
        // amount tolerance only bounds automatic suggestions.
        let outgoing = Self.makeTransaction(accountID: Self.accountA, amount: -50000)
        let incoming = Self.makeTransaction(accountID: Self.accountB, amount: 10)
        #expect(TraccioCore.canLinkAsTransfer(outgoing, incoming))
    }

    @Test func falseForTheSameAccount() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -5000)
        let b = Self.makeTransaction(accountID: Self.accountA, amount: 5000)
        #expect(!TraccioCore.canLinkAsTransfer(a, b))
    }

    @Test func falseForACurrencyMismatch() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -5000, currency: "EUR")
        let b = Self.makeTransaction(accountID: Self.accountB, amount: 5000, currency: "USD")
        #expect(!TraccioCore.canLinkAsTransfer(a, b))
    }

    @Test func falseForTheSameSign() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -5000)
        let b = Self.makeTransaction(accountID: Self.accountB, amount: -5000)
        #expect(!TraccioCore.canLinkAsTransfer(a, b))
    }

    @Test func falseWhenALegIsNotPersonal() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -5000, role: .advance)
        #expect(!TraccioCore.canLinkAsTransfer(a, Self.validIncoming()))
    }

    @Test func falseWhenALegIsRejected() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -5000, status: .rejected)
        #expect(!TraccioCore.canLinkAsTransfer(a, Self.validIncoming()))
    }

    @Test func falseForAZeroAmount() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: 0)
        #expect(!TraccioCore.canLinkAsTransfer(a, Self.validIncoming()))
    }
}

/// Tests for `TraccioCore.canLinkAsFundedPayment(_:_:)` — the client-side
/// gate for which two rows may be linked as a funded payment (ADR 0022).
/// Mirrors `validate_transfer_pair(kind=funded_payment)` the same way
/// `TransferPairingTests` mirrors the two-sided rule.
struct FundedPaymentPairingTests {
    private static let accountA = UUID()
    private static let accountB = UUID()

    private static func makeTransaction(
        accountID: UUID = accountA,
        amount: Int = -5000,
        currency: String = "EUR",
        status: TransactionStatus = .booked,
        role: TransactionRole = .personal
    ) -> TransactionResponse {
        TransactionResponse(
            id: UUID(),
            accountID: accountID,
            amount: amount,
            effectiveAmount: amount,
            currency: currency,
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: status,
            role: role,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil,
            eventID: nil
        )
    }

    /// A valid pair: both outflows, same currency, different accounts, both
    /// personal and booked, non-zero — order does not matter.
    private static func validFunding() -> TransactionResponse {
        makeTransaction(accountID: accountA, amount: -2500)
    }

    private static func validFunded() -> TransactionResponse {
        makeTransaction(accountID: accountB, amount: -5000)
    }

    @Test func trueForAStructurallyValidPair() {
        #expect(TraccioCore.canLinkAsFundedPayment(Self.validFunding(), Self.validFunded()))
    }

    @Test func symmetricInItsArguments() {
        #expect(TraccioCore.canLinkAsFundedPayment(Self.validFunded(), Self.validFunding()))
    }

    @Test func mismatchedMagnitudesAreFine() {
        // A partial top-up (only part of the funded payment came from this
        // leg) is still a structurally valid manual link — the amount
        // tolerance only bounds automatic suggestions.
        let funding = Self.makeTransaction(accountID: Self.accountA, amount: -2500)
        let funded = Self.makeTransaction(accountID: Self.accountB, amount: -50000)
        #expect(TraccioCore.canLinkAsFundedPayment(funding, funded))
    }

    @Test func falseForTheSameAccount() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -2500)
        let b = Self.makeTransaction(accountID: Self.accountA, amount: -5000)
        #expect(!TraccioCore.canLinkAsFundedPayment(a, b))
    }

    @Test func falseForACurrencyMismatch() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -2500, currency: "EUR")
        let b = Self.makeTransaction(accountID: Self.accountB, amount: -5000, currency: "USD")
        #expect(!TraccioCore.canLinkAsFundedPayment(a, b))
    }

    @Test func falseForOppositeSigns() {
        // Two inflows or an opposite-sign pair are never a funded payment —
        // that shape is `canLinkAsTransfer`'s job instead.
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -2500)
        let b = Self.makeTransaction(accountID: Self.accountB, amount: 5000)
        #expect(!TraccioCore.canLinkAsFundedPayment(a, b))
    }

    @Test func falseForTwoInflows() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: 2500)
        let b = Self.makeTransaction(accountID: Self.accountB, amount: 5000)
        #expect(!TraccioCore.canLinkAsFundedPayment(a, b))
    }

    @Test func falseWhenALegIsNotPersonal() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -2500, role: .advance)
        #expect(!TraccioCore.canLinkAsFundedPayment(a, Self.validFunded()))
    }

    @Test func falseWhenALegIsRejected() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: -2500, status: .rejected)
        #expect(!TraccioCore.canLinkAsFundedPayment(a, Self.validFunded()))
    }

    @Test func falseForAZeroAmount() {
        let a = Self.makeTransaction(accountID: Self.accountA, amount: 0)
        #expect(!TraccioCore.canLinkAsFundedPayment(a, Self.validFunded()))
    }
}
