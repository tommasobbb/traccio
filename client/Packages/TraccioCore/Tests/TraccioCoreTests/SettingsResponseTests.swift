import Foundation
import Testing

@testable import TraccioCore

/// Decoding/encoding tests for the settings payloads (ADR 0024, ADR 0029).
///
/// Fixtures are synthetic (`docs/engineering.md`). They pin the wire
/// contract, including the negative cases `docs/engineering.md` requires.
struct SettingsResponseTests {
    @Test func decodesASetDate() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            SettingsResponse.self,
            from: Data(#"{ "tracking_start_date": "2026-07-01", "meal_vouchers_enabled": false }"#.utf8)
        )
        #expect(response.trackingStartDate == CalendarDate(year: 2026, month: 7, day: 1))
        #expect(response.mealVouchersEnabled == false)
    }

    @Test func decodesAnExplicitNullAsNoFloor() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            SettingsResponse.self,
            from: Data(#"{ "tracking_start_date": null, "meal_vouchers_enabled": false }"#.utf8)
        )
        #expect(response.trackingStartDate == nil)
    }

    @Test func decodesMealVouchersEnabledTrue() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            SettingsResponse.self,
            from: Data(#"{ "tracking_start_date": null, "meal_vouchers_enabled": true }"#.utf8)
        )
        #expect(response.mealVouchersEnabled == true)
    }

    @Test func rejectsADateTimeStringInThatField() {
        // A calendar date must not silently accept a full timestamp.
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                SettingsResponse.self,
                from: Data(
                    #"{ "tracking_start_date": "2026-07-01T00:00:00Z", "meal_vouchers_enabled": false }"#
                        .utf8
                )
            )
        }
    }

    @Test func rejectsAMissingMealVouchersEnabledKey() {
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                SettingsResponse.self, from: Data(#"{ "tracking_start_date": null }"#.utf8)
            )
        }
    }

    @Test func setRequestEncodesAnExplicitNullNotAnOmittedKey() throws {
        let data = try JSONEncoder().encode(SetTrackingStartRequest(trackingStartDate: nil))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"tracking_start_date\""))
        #expect(text.contains("null"))
    }

    @Test func setRequestEncodesADateAsABareYyyyMmDd() throws {
        let data = try JSONEncoder().encode(
            SetTrackingStartRequest(trackingStartDate: CalendarDate(year: 2026, month: 7, day: 1))
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["tracking_start_date"] as? String == "2026-07-01")
    }

    @Test func setMealVouchersRequestEncodesTheBoolean() throws {
        let data = try JSONEncoder().encode(SetMealVouchersRequest(enabled: true))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["enabled"] as? Bool == true)
    }

    @Test func decodesASuggestionWithEveryAccountAndTheConstrainingId() throws {
        let json = """
            {
              "suggestion": "2026-07-01",
              "constraining_account_id": "22222222-2222-2222-2222-222222222222",
              "accounts": [
                {
                  "account_id": "11111111-1111-1111-1111-111111111111",
                  "display_name": "Revolut",
                  "earliest": "2026-03-01"
                },
                {
                  "account_id": "22222222-2222-2222-2222-222222222222",
                  "display_name": "Satispay",
                  "earliest": "2026-06-15"
                },
                {
                  "account_id": "33333333-3333-3333-3333-333333333333",
                  "display_name": "Contanti",
                  "earliest": null
                }
              ]
            }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            TrackingStartSuggestionResponse.self, from: Data(json.utf8)
        )

        #expect(response.suggestion == CalendarDate(year: 2026, month: 7, day: 1))
        #expect(
            response.constrainingAccountID == UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )
        #expect(response.accounts.count == 3)
        #expect(response.accounts[2].earliest == nil)
        #expect(response.accounts[0].earliest == CalendarDate(year: 2026, month: 3, day: 1))
    }

    @Test func decodesASuggestionWithNothingToSuggest() throws {
        let json = #"{ "suggestion": null, "constraining_account_id": null, "accounts": [] }"#
        let response = try TraccioCore.jsonDecoder().decode(
            TrackingStartSuggestionResponse.self, from: Data(json.utf8)
        )
        #expect(response.suggestion == nil)
        #expect(response.constrainingAccountID == nil)
        #expect(response.accounts.isEmpty)
    }

    @Test func rejectsASuggestionMissingARequiredField() {
        // `accounts` omitted.
        let json = #"{ "suggestion": null, "constraining_account_id": null }"#
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                TrackingStartSuggestionResponse.self, from: Data(json.utf8)
            )
        }
    }
}
