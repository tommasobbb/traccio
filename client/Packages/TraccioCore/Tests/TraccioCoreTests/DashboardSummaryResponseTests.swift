import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the dashboard summary payload, plus the presentation
/// rule that picks a primary currency to feature.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): round amounts,
/// invented currency mixes.
struct DashboardSummaryResponseTests {
    /// A representative `GET /dashboard/summary` envelope: two currencies,
    /// EUR busier than CHF, matching the shape the backend actually returns
    /// (sorted by currency code, magnitudes for spending/income, a signed net).
    private static let envelope = """
        {
          "currencies": [
            {
              "currency": "CHF",
              "spending": 18000,
              "income": 0,
              "net": -18000,
              "transaction_count": 3
            },
            {
              "currency": "EUR",
              "spending": 124050,
              "income": 210000,
              "net": 85950,
              "transaction_count": 42
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingFieldsAndSign() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            DashboardSummaryResponse.self,
            from: Data(Self.envelope.utf8)
        )

        #expect(response.currencies.count == 2)

        let eur = response.currencies[1]
        #expect(eur.currency == "EUR")
        #expect(eur.spending == 124050)
        #expect(eur.income == 210000)
        #expect(eur.net == 85950)
        #expect(eur.transactionCount == 42)

        let chf = response.currencies[0]
        #expect(chf.currency == "CHF")
        // Spending is a positive magnitude even though the month was a net
        // loss for this currency — only `net` carries the sign.
        #expect(chf.spending == 18000)
        #expect(chf.net == -18000)
    }

    @Test func decodesEmptyCurrenciesAsAValidState() throws {
        // A period with no transactions is a real, empty state — not an
        // error — per ADR 0007.
        let json = """
            { "currencies": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            DashboardSummaryResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.currencies.isEmpty)
    }

    @Test func rejectsMissingRequiredField() {
        // `transaction_count` omitted — every field is required on the wire.
        let json = """
            { "currencies": [
              { "currency": "EUR", "spending": 100, "income": 0, "net": -100 }
            ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                DashboardSummaryResponse.self,
                from: Data(json.utf8)
            )
        }
    }
}

/// Tests for `[CurrencySummaryResponse].primary()` — a presentation-only
/// choice, not a financial derivation (there is no "correct" total across
/// currencies; Traccio never converts between them).
struct PrimaryCurrencyTests {
    @Test func picksTheCurrencyWithMoreTransactions() {
        let eur = CurrencySummaryResponse(
            currency: "EUR", spending: 100, income: 0, net: -100, transactionCount: 42
        )
        let chf = CurrencySummaryResponse(
            currency: "CHF", spending: 100, income: 0, net: -100, transactionCount: 3
        )
        #expect([chf, eur].primary() == eur)
        #expect([eur, chf].primary() == eur)
    }

    @Test func breaksATieOnTheLowerCurrencyCode() {
        let eur = CurrencySummaryResponse(
            currency: "EUR", spending: 100, income: 0, net: -100, transactionCount: 5
        )
        let chf = CurrencySummaryResponse(
            currency: "CHF", spending: 100, income: 0, net: -100, transactionCount: 5
        )
        #expect([eur, chf].primary() == chf)
        #expect([chf, eur].primary() == chf)
    }

    @Test func returnsNilForAnEmptyList() {
        let empty: [CurrencySummaryResponse] = []
        #expect(empty.primary() == nil)
    }
}
