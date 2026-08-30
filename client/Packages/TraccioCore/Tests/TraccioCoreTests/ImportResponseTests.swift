import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the file-import payloads (ADR 0023).
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented ids,
/// round amounts. They pin the wire contract including the negative cases
/// `client/CLAUDE.md` requires (unknown enum, missing required field).
struct ImportResponseTests {
    private static let previewEnvelope = """
        {
          "rows": [
            {
              "row_number": 1,
              "status": "new",
              "reason": null,
              "target_account_id": "11111111-1111-1111-1111-111111111111",
              "amount": -200,
              "currency": "EUR",
              "value_date": "2026-06-25T19:56:00+00:00",
              "description": "TEST MERCHANT 01"
            },
            {
              "row_number": 1,
              "status": "already_imported",
              "reason": null,
              "target_account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -4000,
              "currency": "EUR",
              "value_date": "2026-06-25T19:56:00+00:00",
              "description": "TEST MERCHANT 01"
            },
            {
              "row_number": 2,
              "status": "invalid",
              "reason": "amount_split_mismatch",
              "target_account_id": null,
              "amount": null,
              "currency": null,
              "value_date": null,
              "description": null
            }
          ],
          "summary": { "new": 1, "already_imported": 1, "invalid": 1, "total": 3 }
        }
        """

    @Test func decodesAPreviewPreservingEveryFieldAndStatus() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            ImportPreviewResponse.self, from: Data(Self.previewEnvelope.utf8)
        )

        #expect(response.summary == ImportPreviewSummaryResponse(new: 1, alreadyImported: 1, invalid: 1, total: 3))
        #expect(response.rows.map(\.status) == [.new, .alreadyImported, .invalid])
        #expect(response.rows[0].amount == -200)
        #expect(
            response.rows[0].targetAccountID == UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        // An invalid row carries only the row number, status, and reason.
        let invalid = response.rows[2]
        #expect(invalid.reason == "amount_split_mismatch")
        #expect(invalid.amount == nil)
        #expect(invalid.targetAccountID == nil)
        #expect(invalid.valueDate == nil)
    }

    @Test func rejectsAnUnknownRowStatus() {
        let json = """
            {
              "rows": [ {
                "row_number": 1, "status": "maybe", "reason": null,
                "target_account_id": null, "amount": null, "currency": null,
                "value_date": null, "description": null
              } ],
              "summary": { "new": 0, "already_imported": 0, "invalid": 1, "total": 1 }
            }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(ImportPreviewResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsAPreviewRowMissingARequiredField() {
        // `status` omitted.
        let json = """
            {
              "rows": [ { "row_number": 1, "reason": null, "target_account_id": null,
                "amount": null, "currency": null, "value_date": null, "description": null } ],
              "summary": { "new": 0, "already_imported": 0, "invalid": 1, "total": 1 }
            }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(ImportPreviewResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesACommitResult() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            ImportCommitResponse.self,
            from: Data(#"{ "imported": 2, "skipped": 0, "invalid": 1 }"#.utf8)
        )
        #expect(response == ImportCommitResponse(imported: 2, skipped: 0, invalid: 1))
    }

    @Test func rejectsACommitResultMissingAField() {
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                ImportCommitResponse.self, from: Data(#"{ "imported": 2, "skipped": 0 }"#.utf8)
            )
        }
    }

    @Test func encodesARequestWithSnakeCaseKeysAndOmitsAnAbsentVoucher() throws {
        let request = ImportPreviewRequest(
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            voucherAccountID: nil,
            profile: "satispay",
            filename: "june.xlsx",
            contentBase64: "UEsDBAo="
        )

        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["account_id"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(object?["profile"] as? String == "satispay")
        #expect(object?["content_base64"] as? String == "UEsDBAo=")
        #expect(object?.keys.contains("voucher_account_id") == false)
    }
}
