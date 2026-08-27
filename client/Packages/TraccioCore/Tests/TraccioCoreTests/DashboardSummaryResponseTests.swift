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
    /// EUR busier than CHF. EUR's `by_category` shows a root with one child
    /// rolled up (ADR 0018's hierarchy) alongside the "no category" bucket;
    /// EUR also carries a comparison period.
    private static let envelope = """
        {
          "currencies": [
            {
              "currency": "CHF",
              "spending": 18000,
              "income": 0,
              "net": -18000,
              "transaction_count": 3,
              "average_daily_spending": null,
              "by_category": [
                {
                  "category_id": null, "category_name": null, "color": null, "icon": null,
                  "spending": 18000, "income": 0, "transaction_count": 3,
                  "direct_spending": 18000, "direct_income": 0, "direct_transaction_count": 3,
                  "children": []
                }
              ],
              "by_bucket": [
                {
                  "start": "2026-08-10", "end": "2026-08-11",
                  "spending": 18000, "income": 0, "transaction_count": 3
                }
              ],
              "by_account": [],
              "comparison": null
            },
            {
              "currency": "EUR",
              "spending": 124050,
              "income": 210000,
              "net": 85950,
              "transaction_count": 42,
              "average_daily_spending": 4135,
              "by_category": [
                {
                  "category_id": "8f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
                  "category_name": "Dining out", "color": "orange", "icon": "dining",
                  "spending": 60000, "income": 0, "transaction_count": 20,
                  "direct_spending": 45000, "direct_income": 0, "direct_transaction_count": 15,
                  "children": [
                    {
                      "category_id": "9f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
                      "category_name": "Coffee", "color": "orange", "icon": "coffee",
                      "spending": 15000, "income": 0, "transaction_count": 5
                    }
                  ]
                },
                {
                  "category_id": null, "category_name": null, "color": null, "icon": null,
                  "spending": 64050, "income": 210000, "transaction_count": 22,
                  "direct_spending": 64050, "direct_income": 210000, "direct_transaction_count": 22,
                  "children": []
                }
              ],
              "by_bucket": [
                {
                  "start": "2026-08-10", "end": "2026-08-11",
                  "spending": 60000, "income": 100000, "transaction_count": 21
                },
                {
                  "start": "2026-08-12", "end": "2026-08-13",
                  "spending": 64050, "income": 110000, "transaction_count": 21
                }
              ],
              "by_account": [
                {
                  "account_id": "aaaaaaaa-ceea-467e-a63c-58ba7d6c1a9e",
                  "account_name": "Conto principale", "color": "blue", "icon": "bank",
                  "spending": 124050, "income": 210000, "transaction_count": 42
                }
              ],
              "comparison": {
                "spending": 100000, "income": 180000, "net": 80000,
                "spending_delta": 24050, "spending_delta_pct": 0.2405
              }
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
        #expect(eur.averageDailySpending == 4135)
        #expect(eur.byCategory.count == 2)

        let diningOut = eur.byCategory[0]
        #expect(diningOut.categoryName == "Dining out")
        #expect(diningOut.spending == 60000)
        #expect(diningOut.directSpending == 45000)
        #expect(diningOut.children.count == 1)
        #expect(diningOut.children[0].categoryName == "Coffee")
        #expect(diningOut.children[0].spending == 15000)

        // The "no category" bucket is a real entry, never omitted.
        #expect(eur.byCategory[1].categoryID == nil)
        #expect(eur.byCategory[1].categoryName == nil)

        #expect(eur.byBucket.count == 2)
        #expect(eur.byBucket[0].start == CalendarDate(year: 2026, month: 8, day: 10))
        #expect(eur.byBucket[0].end == CalendarDate(year: 2026, month: 8, day: 11))
        #expect(eur.byBucket[0].spending == 60000)
        #expect(eur.byBucket[1].start == CalendarDate(year: 2026, month: 8, day: 12))

        #expect(eur.byAccount.count == 1)
        #expect(eur.byAccount[0].accountName == "Conto principale")
        #expect(eur.byAccount[0].spending == 124050)

        #expect(eur.comparison?.spending == 100000)
        #expect(eur.comparison?.spendingDelta == 24050)
        #expect(eur.comparison?.spendingDeltaPct == 0.2405)

        let chf = response.currencies[0]
        #expect(chf.currency == "CHF")
        // Spending is a positive magnitude even though the month was a net
        // loss for this currency — only `net` carries the sign.
        #expect(chf.spending == 18000)
        #expect(chf.net == -18000)
        #expect(chf.averageDailySpending == nil)
        #expect(chf.byCategory.count == 1)
        #expect(chf.byBucket.count == 1)
        #expect(chf.byAccount.isEmpty)
        #expect(chf.comparison == nil)
    }

    @Test func decodesEmptyPartitionsAsAValidState() throws {
        // A currency summary can legitimately carry no categories, buckets,
        // or accounts at all (e.g. every transaction rejected) — an empty
        // array, not a missing key.
        let json = """
            { "currencies": [
              {
                "currency": "EUR", "spending": 0, "income": 0, "net": 0,
                "transaction_count": 0, "average_daily_spending": null,
                "by_category": [], "by_bucket": [], "by_account": [], "comparison": null
              }
            ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            DashboardSummaryResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.currencies[0].byCategory.isEmpty)
        #expect(response.currencies[0].byBucket.isEmpty)
        #expect(response.currencies[0].byAccount.isEmpty)
    }

    @Test func rejectsMissingByCategoryField() {
        // `by_category` is required on the wire — the backend never omits it.
        let json = """
            { "currencies": [
              {
                "currency": "EUR", "spending": 100, "income": 0, "net": -100,
                "transaction_count": 1, "average_daily_spending": null,
                "by_bucket": [], "by_account": [], "comparison": null
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

    @Test func rejectsMissingByBucketField() {
        // `by_bucket` is required on the wire — the backend never omits it.
        let json = """
            { "currencies": [
              {
                "currency": "EUR", "spending": 100, "income": 0, "net": -100,
                "transaction_count": 1, "average_daily_spending": null,
                "by_category": [], "by_account": [], "comparison": null
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

    // MARK: converted total (ADR 0021)

    @Test func decodesAMissingConvertedBlockAsNil() throws {
        // FX off (the default) — the two new keys are absent, not null.
        let response = try TraccioCore.jsonDecoder().decode(
            DashboardSummaryResponse.self, from: Data(Self.envelope.utf8)
        )
        #expect(response.converted == nil)
        #expect(response.conversionUnavailable == nil)
    }

    @Test func decodesAConvertedTotalWithItsRates() throws {
        let json = """
            {
              "currencies": [
                {
                  "currency": "USD", "spending": 12000, "income": 0, "net": -12000,
                  "transaction_count": 2, "average_daily_spending": null,
                  "by_category": [], "by_bucket": [], "by_account": [], "comparison": null
                }
              ],
              "converted": {
                "summary": {
                  "currency": "EUR", "spending": 10300, "income": 0, "net": -10300,
                  "transaction_count": 2, "average_daily_spending": null,
                  "by_category": [], "by_bucket": [], "by_account": [], "comparison": null
                },
                "rates": [
                  { "source_currency": "USD", "rate": "0.857", "rate_date": "2026-08-26" }
                ],
                "basis": "historical"
              },
              "conversion_unavailable": null
            }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            DashboardSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(response.conversionUnavailable == nil)
        let converted = try #require(response.converted)
        #expect(converted.summary.currency == "EUR")
        #expect(converted.summary.spending == 10300)
        #expect(converted.basis == "historical")
        #expect(converted.rates.count == 1)
        #expect(converted.rates[0].sourceCurrency == "USD")
        #expect(converted.rates[0].rate == "0.857")
        #expect(converted.rates[0].rateDate == CalendarDate(year: 2026, month: 8, day: 26))
    }

    @Test func decodesAConversionUnavailableReasonWithNoConvertedBlock() throws {
        let json = """
            { "currencies": [], "converted": null, "conversion_unavailable": "rates_unavailable" }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            DashboardSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(response.converted == nil)
        #expect(response.conversionUnavailable == "rates_unavailable")
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

/// Decoding tests for `CategorySummaryResponse` (the child type) in
/// isolation, covering the negative cases per `client/CLAUDE.md`'s "a
/// decoding test per model".
struct CategorySummaryResponseTests {
    @Test func decodesAChildWithColorAndIcon() throws {
        let json = """
            {
              "category_id": "8f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
              "category_name": "Coffee", "color": "orange", "icon": "coffee",
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            CategorySummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.categoryName == "Coffee")
        #expect(entry.color == .orange)
        #expect(entry.icon == .coffee)
    }

    @Test func decodesANullDisplayFromTheDeleteRace() throws {
        let json = """
            {
              "category_id": "8f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
              "category_name": null, "color": null, "icon": null,
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            CategorySummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.categoryName == nil)
    }

    @Test func rejectsAMissingCategoryID() {
        // Unlike the root type, a child's category_id is never null.
        let json = """
            {
              "category_id": null, "category_name": "Coffee", "color": null, "icon": null,
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
              "category_id": "8f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
              "category_name": null, "color": null, "icon": null,
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

/// Decoding tests for `CategoryGroupSummaryResponse` (the root type) in
/// isolation.
struct CategoryGroupSummaryResponseTests {
    @Test func decodesTheNoCategoryBucketWithNoChildren() throws {
        let json = """
            {
              "category_id": null, "category_name": null, "color": null, "icon": null,
              "spending": 5000, "income": 0, "transaction_count": 2,
              "direct_spending": 5000, "direct_income": 0, "direct_transaction_count": 2,
              "children": []
            }
            """
        let group = try TraccioCore.jsonDecoder().decode(
            CategoryGroupSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(group.categoryID == nil)
        #expect(group.children.isEmpty)
    }

    @Test func decodesARootWithAChildRolledUp() throws {
        let json = """
            {
              "category_id": "8f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
              "category_name": "Dining out", "color": "orange", "icon": "dining",
              "spending": 6000, "income": 0, "transaction_count": 3,
              "direct_spending": 4000, "direct_income": 0, "direct_transaction_count": 2,
              "children": [
                {
                  "category_id": "9f14e45f-ceea-467e-a63c-58ba7d6c1a9e",
                  "category_name": "Coffee", "color": "orange", "icon": "coffee",
                  "spending": 2000, "income": 0, "transaction_count": 1
                }
              ]
            }
            """
        let group = try TraccioCore.jsonDecoder().decode(
            CategoryGroupSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(group.spending == 6000)
        #expect(group.directSpending == 4000)
        #expect(group.children.count == 1)
        #expect(group.children[0].spending == 2000)
    }

    @Test func rejectsMissingDirectSpending() {
        let json = """
            {
              "category_id": null, "category_name": null, "color": null, "icon": null,
              "spending": 5000, "income": 0, "transaction_count": 2,
              "direct_income": 0, "direct_transaction_count": 2, "children": []
            }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                CategoryGroupSummaryResponse.self, from: Data(json.utf8)
            )
        }
    }
}

/// Decoding tests for `BucketSummaryResponse` in isolation, covering the
/// negative cases per `client/CLAUDE.md`'s "a decoding test per model".
struct BucketSummaryResponseTests {
    @Test func decodesStartAndEndAsBareCalendarDates() throws {
        let json = """
            {
              "start": "2026-08-10", "end": "2026-08-11",
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            BucketSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.start == CalendarDate(year: 2026, month: 8, day: 10))
        #expect(entry.end == CalendarDate(year: 2026, month: 8, day: 11))
        #expect(entry.spending == 5000)
    }

    @Test func rejectsAMalformedStart() {
        let json = """
            { "start": "10/08/2026", "end": "2026-08-11", "spending": 5000, "income": 0, "transaction_count": 2 }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                BucketSummaryResponse.self, from: Data(json.utf8)
            )
        }
    }

    @Test func rejectsADateTimeInsteadOfABareDate() {
        // `start`/`end` are calendar dates, not instants — a full date-time
        // string must not silently decode and drop its time component.
        let json = """
            { "start": "2026-08-10T00:00:00Z", "end": "2026-08-11", "spending": 5000, "income": 0, "transaction_count": 2 }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                BucketSummaryResponse.self, from: Data(json.utf8)
            )
        }
    }

    @Test func rejectsMissingTransactionCount() {
        let json = """
            { "start": "2026-08-10", "end": "2026-08-11", "spending": 5000, "income": 0 }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                BucketSummaryResponse.self, from: Data(json.utf8)
            )
        }
    }
}

/// Decoding tests for `AccountSummaryResponse` in isolation.
struct AccountSummaryResponseTests {
    @Test func decodesAnAccountWithDisplayFields() throws {
        let json = """
            {
              "account_id": "aaaaaaaa-ceea-467e-a63c-58ba7d6c1a9e",
              "account_name": "Conto principale", "color": "blue", "icon": "bank",
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            AccountSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.accountName == "Conto principale")
        #expect(entry.color == .blue)
        #expect(entry.icon == .bank)
    }

    @Test func decodesANullDisplayFromTheDeleteRace() throws {
        let json = """
            {
              "account_id": "aaaaaaaa-ceea-467e-a63c-58ba7d6c1a9e",
              "account_name": null, "color": null, "icon": null,
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            AccountSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.accountName == nil)
    }

    @Test func rejectsMissingAccountID() {
        let json = """
            {
              "account_name": null, "color": null, "icon": null,
              "spending": 5000, "income": 0, "transaction_count": 2
            }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                AccountSummaryResponse.self, from: Data(json.utf8)
            )
        }
    }
}

/// Decoding tests for `ComparisonSummaryResponse` in isolation.
struct ComparisonSummaryResponseTests {
    @Test func decodesASignedDeltaAndAPct() throws {
        let json = """
            { "spending": 3000, "income": 1000, "net": -2000, "spending_delta": 2000, "spending_delta_pct": 0.6667 }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            ComparisonSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.spendingDelta == 2000)
        #expect(entry.spendingDeltaPct == 0.6667)
    }

    @Test func decodesANullPctOnAZeroBase() throws {
        let json = """
            { "spending": 0, "income": 0, "net": 0, "spending_delta": 5000, "spending_delta_pct": null }
            """
        let entry = try TraccioCore.jsonDecoder().decode(
            ComparisonSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(entry.spendingDeltaPct == nil)
    }

    @Test func rejectsMissingSpendingDelta() {
        let json = """
            { "spending": 0, "income": 0, "net": 0, "spending_delta_pct": null }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                ComparisonSummaryResponse.self, from: Data(json.utf8)
            )
        }
    }
}
