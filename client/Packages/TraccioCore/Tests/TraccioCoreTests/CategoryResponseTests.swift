import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the categories payload.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`) — invented names,
/// no financial data (a category has none).
struct CategoryResponseTests {
    @Test func decodesEnvelopePreservingOrderAndFields() throws {
        let json = """
            {
              "categories": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "name": "Alimentari",
                  "created_at": "2026-08-10T09:30:00+00:00"
                },
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "name": "Svago",
                  "created_at": "2026-08-11T10:00:00"
                }
              ]
            }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            CategoriesResponse.self, from: Data(json.utf8)
        )
        #expect(response.categories.count == 2)
        #expect(response.categories[0].name == "Alimentari")
        #expect(response.categories[1].name == "Svago")
    }

    @Test func rejectsMissingRequiredField() {
        // `name` omitted.
        let json = """
            { "categories": [
              { "id": "11111111-1111-1111-1111-111111111111", "created_at": "2026-08-10T09:30:00+00:00" }
            ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(CategoriesResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyCategoriesAsAValidState() throws {
        let json = """
            { "categories": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            CategoriesResponse.self, from: Data(json.utf8)
        )
        #expect(response.categories.isEmpty)
    }
}
