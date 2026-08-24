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
              "transaction_count": 3,
              "by_category": [
                {
                  "category_id": null,
                  "category_name": null,
                  "spending": 18000,
                  "income": 0,
                  "transaction_count": 3
                }
              ],
              "by_day": [
                {
                  "date": "2026-08-10",
                  "spending": 18000,
                  "income": 0,
                  "transaction_count": 3
                }
              ]
            },
            {
              "currency": "EUR",
              "spending": 124050,
              "income": 210000,
              "net": 85950,
              "transaction_count": 42,
              "by_category": [
                {
                  "category_id": "8f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
                  "category_name": "Groceries",
                  "spending": 60000,
                  "income": 0,
                  "transaction_count": 20
                },
                {
                  "category_id": null,
                  "category_name": null,
                  "spending": 64050,
                  "income": 210000,
                  "transaction_count": 22
                }
              ],
              "by_day": [
                {
                  "date": "2026-08-10",
                  "spending": 60000,
                  "income": 100000,
                  "transaction_count": 21
                },
                {
                  "date": "2026-08-12",
                  "spending": 64050,
                  "income": 110000,
                  "transaction_count": 21
                }
              ]
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
        #expect(eur.byCategory.count == 2)
        #expect(eur.byCategory[0].categoryName == "Groceries")
        #expect(eur.byCategory[0].spending == 60000)
        // The "no category" bucket is a real entry, never omitted.
        #expect(eur.byCategory[1].categoryID == nil)
        #expect(eur.byCategory[1].categoryName == nil)
        #expect(eur.byDay.count == 2)
        #expect(eur.byDay[0].date == CalendarDate(year: 2026, month: 8, day: 10))
        #expect(eur.byDay[0].spending == 60000)
        #expect(eur.byDay[1].date == CalendarDate(year: 2026, month: 8, day: 12))

        let chf = response.currencies[0]
        #expect(chf.currency == "CHF")
        // Spending is a positive magnitude even though the month was a net
        // loss for this currency — only `net` carries the sign.
        #expect(chf.spending == 18000)
        #expect(chf.net == -18000)
        #expect(chf.byCategory.count == 1)
        #expect(chf.byDay.count == 1)
    }

    @Test func decodesEmptyByCategoryAndByDayAsAValidState() throws {
        // A currency summary can legitimately carry no categories or days at
        // all (e.g. every transaction rejected) — an empty array, not a
        // missing key.
        let json = """
            { "currencies": [
              {
                "currency": "EUR", "spending": 0, "income": 0, "net": 0,
                "transaction_count": 0, "by_category": [], "by_day": []
              }
            ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            DashboardSummaryResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.currencies[0].byCategory.isEmpty)
        #expect(response.currencies[0].byDay.isEmpty)
    }

    @Test func rejectsMissingByCategoryField() {
        // `by_category` is required on the wire — the backend never omits it.
        let json = """
            { "currencies": [
              {
                "currency": "EUR", "spending": 100, "income": 0, "net": -100,
                "transaction_count": 1, "by_day": []
              }
            ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                DashboardSummaryResponse.self,
                from: Data(json.utf8)
            )
        }
    }

    @Test func rejectsMissingByDayField() {
        // `by_day` is required on the wire — the backend never omits it.
        let json = """
            { "currencies": [
              {
                "currency": "EUR", "spending": 100, "income": 0, "net": -100,
                "transaction_count": 1, "by_category": []
              }
            ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                DashboardSummaryResponse.self,
                from: Data(json.utf8)
            )
        }
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

/// Decoding tests for `CategorySummaryResponse` in isolation, covering the
/// negative cases per `client/CLAUDE.md`'s "a decoding test per model".
struct CategorySummaryResponseTests {
    @Test func decodesTheNoCategoryBucket() throws {
        let json = """
            {
              "category_id": null, "category_name": null,
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            CategorySummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.categoryID == nil)
        #expect(entry.categoryName == nil)
    }

    @Test func rejectsAMalformedCategoryID() {
        let json = """
            {
              "category_id": "not-a-uuid", "category_name": "Groceries",
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                CategorySummaryResponse.self, from: Data(json.utf8)
            )
        }
    }

    @Test func rejectsMissingTransactionCount() {
        let json = """
            {
              "category_id": null, "category_name": null,
              "spending": 5000, "income": 0
            }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                CategorySummaryResponse.self, from: Data(json.utf8)
            )
        }
    }
}

/// Decoding tests for `DaySummaryResponse` in isolation, covering the
/// negative cases per `client/CLAUDE.md`'s "a decoding test per model".
struct DaySummaryResponseTests {
    @Test func decodesABareCalendarDate() throws {
        let json = """
            { "date": "2026-08-10", "spending": 5000, "income": 0, "transaction_count": 2 }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            DaySummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.date == CalendarDate(year: 2026, month: 8, day: 10))
        #expect(entry.spending == 5000)
    }

    @Test func rejectsAMalformedDate() {
        let json = """
            { "date": "10/08/2026", "spending": 5000, "income": 0, "transaction_count": 2 }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                DaySummaryResponse.self, from: Data(json.utf8)
            )
        }
    }

    @Test func rejectsADateTimeInsteadOfABareDate() {
        // `date` is a calendar date, not an instant — a full date-time string
        // must not silently decode and drop its time component.
        let json = """
            { "date": "2026-08-10T00:00:00Z", "spending": 5000, "income": 0, "transaction_count": 2 }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                DaySummaryResponse.self, from: Data(json.utf8)
            )
        }
    }

    @Test func rejectsMissingTransactionCount() {
        let json = """
            { "date": "2026-08-10", "spending": 5000, "income": 0 }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                DaySummaryResponse.self, from: Data(json.utf8)
            )
        }
    }
}
