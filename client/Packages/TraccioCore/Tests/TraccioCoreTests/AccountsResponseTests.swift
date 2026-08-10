import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the accounts payload.
///
/// Fixtures are synthetic (invented ids, no real financial data — these DTOs
/// carry no IBANs or amounts anyway). They pin the wire contract: field name
/// mapping, the `AccountKind` enum, `null` handling, ordering, and the date
/// strategy. A backend field rename breaks these rather than silently
/// producing `nil`.
struct AccountsResponseTests {
    /// A representative `GET /accounts` envelope: two accounts, one named and
    /// timezone-aware with fractional seconds, one unnamed and offset-less.
    private static let envelope = """
        {
          "accounts": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "connection_id": "22222222-2222-2222-2222-222222222222",
              "kind": "current",
              "currency": "EUR",
              "name": "Test Current",
              "created_at": "2026-08-10T09:30:00.123456+00:00"
            },
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "connection_id": "22222222-2222-2222-2222-222222222222",
              "kind": "card",
              "currency": "EUR",
              "name": null,
              "created_at": "2026-08-11T10:00:00"
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingOrderAndFields() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            AccountsResponse.self,
            from: Data(Self.envelope.utf8)
        )

        #expect(response.accounts.count == 2)

        let first = response.accounts[0]
        #expect(first.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(first.connectionID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(first.kind == .current)
        #expect(first.currency == "EUR")
        #expect(first.name == "Test Current")

        let second = response.accounts[1]
        #expect(second.kind == .card)
        #expect(second.name == nil)
    }

    @Test func decodesBothTimezoneAwareAndNaiveTimestamps() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            AccountsResponse.self,
            from: Data(Self.envelope.utf8)
        )

        // Aware, fractional: 2026-08-10T09:30:00.123456Z.
        var aware = DateComponents()
        aware.year = 2026; aware.month = 8; aware.day = 10
        aware.hour = 9; aware.minute = 30; aware.second = 0
        aware.timeZone = TimeZone(identifier: "UTC")
        let awareExpected = Calendar(identifier: .iso8601).date(from: aware)!
        // Within a second (fractional part is truncated by the comparison).
        #expect(abs(response.accounts[0].createdAt.timeIntervalSince(awareExpected)) < 1)

        // Naive, assumed UTC: 2026-08-11T10:00:00.
        var naive = DateComponents()
        naive.year = 2026; naive.month = 8; naive.day = 11
        naive.hour = 10; naive.minute = 0; naive.second = 0
        naive.timeZone = TimeZone(identifier: "UTC")
        let naiveExpected = Calendar(identifier: .iso8601).date(from: naive)!
        #expect(response.accounts[1].createdAt == naiveExpected)
    }

    @Test func rejectsUnknownAccountKind() {
        let json = """
            { "accounts": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "connection_id": "22222222-2222-2222-2222-222222222222",
              "kind": "crypto",
              "currency": "EUR",
              "name": null,
              "created_at": "2026-08-10T09:30:00+00:00"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                AccountsResponse.self,
                from: Data(json.utf8)
            )
        }
    }

    @Test func rejectsMalformedTimestamp() {
        let json = """
            { "accounts": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "connection_id": "22222222-2222-2222-2222-222222222222",
              "kind": "current",
              "currency": "EUR",
              "name": null,
              "created_at": "not-a-date"
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(
                AccountsResponse.self,
                from: Data(json.utf8)
            )
        }
    }
}
