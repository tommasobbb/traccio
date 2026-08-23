import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.formatMoney`. Pinned to `en_US_POSIX`-independent
/// assertions (checking substrings, not exact locale output) since the
/// formatter deliberately follows the current locale rather than a fixed one.
struct MoneyFormatterTests {
    @Test func formatsAPositiveAmountWithTheCurrencySymbol() {
        let formatted = TraccioCore.formatMoney(amount: 124_050, currencyCode: "EUR")
        // Locale-dependent grouping/decimal marks, but the digits and a euro
        // sign must both be present.
        #expect(formatted.contains("1240") || formatted.contains("1.240") || formatted.contains("1,240"))
        #expect(formatted.contains("€"))
    }

    @Test func doesNotSignByDefault() {
        let formatted = TraccioCore.formatMoney(amount: 210_000, currencyCode: "EUR")
        #expect(!formatted.hasPrefix("+"))
    }

    @Test func addsAnExplicitPlusWhenRequestedAndPositive() {
        let formatted = TraccioCore.formatMoney(amount: 210_000, currencyCode: "EUR", explicitSign: true)
        #expect(formatted.hasPrefix("+"))
    }

    @Test func doesNotSignZeroEvenWhenExplicitSignIsRequested() {
        let formatted = TraccioCore.formatMoney(amount: 0, currencyCode: "EUR", explicitSign: true)
        #expect(!formatted.hasPrefix("+"))
    }

    @Test func formatsANegativeAmountWithoutDoubleSigning() {
        let formatted = TraccioCore.formatMoney(amount: -1800, currencyCode: "CHF", explicitSign: true)
        // A negative amount is never re-signed with the explicit "+".
        #expect(!formatted.hasPrefix("+"))
    }

    @Test func fallsBackGracefullyForAnUnrecognisedCurrencyCode() {
        // "XXX" is what Traccio's wallet accounts (e.g. PayPal) report at the
        // account level — must format without crashing or silently mangling
        // the amount.
        let formatted = TraccioCore.formatMoney(amount: 500, currencyCode: "XXX")
        #expect(formatted.contains("5.00") || formatted.contains("5,00"))
        #expect(formatted.contains("XXX"))
    }

    @Test func parseMoneyInputAcceptsADotDecimalSeparator() {
        #expect(TraccioCore.parseMoneyInput("18.50") == 1850)
    }

    @Test func parseMoneyInputAcceptsACommaDecimalSeparator() {
        #expect(TraccioCore.parseMoneyInput("18,50") == 1850)
    }

    @Test func parseMoneyInputAcceptsAWholeNumberWithNoDecimalPart() {
        #expect(TraccioCore.parseMoneyInput("20") == 2000)
    }

    @Test func parseMoneyInputReturnsNilForEmptyInput() {
        #expect(TraccioCore.parseMoneyInput("") == nil)
        #expect(TraccioCore.parseMoneyInput("   ") == nil)
    }

    @Test func parseMoneyInputReturnsNilForMalformedInput() {
        #expect(TraccioCore.parseMoneyInput("not a number") == nil)
    }

    @Test func parseMoneyInputReturnsNilForNegativeInput() {
        // Every field this feeds (own_share, expected_amount, a
        // reimbursement amount) is a positive magnitude on the wire.
        #expect(TraccioCore.parseMoneyInput("-5") == nil)
    }

    @Test func parseMoneyInputAcceptsZero() {
        #expect(TraccioCore.parseMoneyInput("0") == 0)
    }
}
