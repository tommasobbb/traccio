import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for `GET /connections/institutions`.
///
/// Fixtures are synthetic (`docs/engineering.md`): invented bank
/// names, no real institution data.
struct InstitutionResponseTests {
    @Test func decodesEnvelopePreservingFields() throws {
        let json = """
            { "institutions": [
              { "name": "TEST BANK 01", "country": "IT", "logo": "https://logos.example.test/tb01/" },
              { "name": "TEST BANK 02", "country": "IT", "logo": null }
            ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            InstitutionsResponse.self, from: Data(json.utf8)
        )
        #expect(response.institutions.count == 2)
        #expect(response.institutions[0].name == "TEST BANK 01")
        #expect(response.institutions[0].country == "IT")
        #expect(response.institutions[0].logo == "https://logos.example.test/tb01/")
        #expect(response.institutions[1].name == "TEST BANK 02")
        #expect(response.institutions[1].logo == nil)
    }

    @Test func decodesAMissingLogoKeyAsNil() throws {
        let json = """
            { "institutions": [ { "name": "TEST BANK 01", "country": "IT" } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            InstitutionsResponse.self, from: Data(json.utf8)
        )
        #expect(response.institutions[0].logo == nil)
    }

    @Test func decodesEmptyInstitutionsAsAValidState() throws {
        let json = """
            { "institutions": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            InstitutionsResponse.self, from: Data(json.utf8)
        )
        #expect(response.institutions.isEmpty)
    }

    @Test func rejectsMissingRequiredField() {
        let json = """
            { "institutions": [ { "name": "TEST BANK 01" } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(InstitutionsResponse.self, from: Data(json.utf8))
        }
    }
}
