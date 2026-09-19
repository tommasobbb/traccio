import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for `GET /events/{id}/summary` (ADR 0028).
///
/// Fixtures are synthetic (`docs/engineering.md`). They pin that
/// `by_category` is the same shape the dashboard returns, so the event
/// breakdown reuses `donutSegments` / `breakdownRows` unchanged.
struct EventSummaryResponseTests {
    @Test func decodesFiguresAndTheCategoryBreakdown() throws {
        let json = """
            {
              "spending": 7500,
              "income": 1000,
              "net": -6500,
              "currency": "EUR",
              "by_category": [
                {
                  "category_id": "11111111-1111-1111-1111-111111111111",
                  "category_name": "Trasporti",
                  "color": "blue",
                  "icon": "transport",
                  "spending": 5000,
                  "income": 0,
                  "transaction_count": 1,
                  "direct_spending": 5000,
                  "direct_income": 0,
                  "direct_transaction_count": 1,
                  "children": []
                },
                {
                  "category_id": null,
                  "category_name": null,
                  "color": null,
                  "icon": null,
                  "spending": 2500,
                  "income": 1000,
                  "transaction_count": 2,
                  "direct_spending": 2500,
                  "direct_income": 1000,
                  "direct_transaction_count": 2,
                  "children": []
                }
              ]
            }
            """
        let summary = try TraccioCore.jsonDecoder().decode(
            EventSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(summary.spending == 7500)
        #expect(summary.income == 1000)
        #expect(summary.net == -6500)
        #expect(summary.currency == "EUR")
        #expect(summary.byCategory.count == 2)
        #expect(summary.byCategory[0].categoryName == "Trasporti")
        #expect(summary.byCategory[1].categoryID == nil)

        // The dashboard's own helpers consume it unchanged.
        #expect(!TraccioCore.donutSegments(summary.byCategory).isEmpty)
    }

    @Test func decodesAnEmptyEventSummary() throws {
        let json = """
            { "spending": 0, "income": 0, "net": 0, "currency": null, "by_category": [] }
            """
        let summary = try TraccioCore.jsonDecoder().decode(
            EventSummaryResponse.self, from: Data(json.utf8)
        )
        #expect(summary.currency == nil)
        #expect(summary.byCategory.isEmpty)
    }

    @Test func rejectsAMissingRequiredField() {
        // `net` omitted — every top-level field is required.
        let json = """
            { "spending": 0, "income": 0, "currency": null, "by_category": [] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(EventSummaryResponse.self, from: Data(json.utf8))
        }
    }
}
