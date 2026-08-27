import Foundation
import Testing

@testable import TraccioCore

/// Decoding tests for the connections payload.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented bank
/// name, no real consent data. They pin the wire contract: field name
/// mapping, every `ConsentState`/`ConnectionStatus` case, the nullable
/// fields, and an unknown enum value failing to decode rather than being
/// silently dropped.
struct ConnectionResponseTests {
    private static let envelope = """
        {
          "connections": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "provider": "enable_banking",
              "institution_name": "Revolut",
              "institution_logo": "https://enablebanking.com/brands/IT/Revolut/",
              "status": "active",
              "consent_state": "expiring_soon",
              "days_until_expiry": 9,
              "expires_at": "2026-09-01T00:00:00+00:00",
              "created_at": "2026-08-01T09:30:00+00:00",
              "last_synced_at": "2026-08-23T09:26:00+00:00",
              "background_sync_enabled": true,
              "sync_budget_remaining": 3,
              "next_sync_at": "2026-08-24T13:00:00+00:00"
            }
          ]
        }
        """

    @Test func decodesEnvelopePreservingFields() throws {
        let response = try TraccioCore.jsonDecoder().decode(
            ConnectionsResponse.self, from: Data(Self.envelope.utf8)
        )

        #expect(response.connections.count == 1)
        let connection = response.connections[0]
        #expect(connection.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(connection.provider == "enable_banking")
        #expect(connection.institutionName == "Revolut")
        #expect(connection.institutionLogo == "https://enablebanking.com/brands/IT/Revolut/")
        #expect(connection.status == .active)
        #expect(connection.consentState == .expiringSoon)
        #expect(connection.daysUntilExpiry == 9)
        #expect(connection.expiresAt != nil)
        #expect(connection.lastSyncedAt != nil)
        #expect(connection.backgroundSyncEnabled == true)
        #expect(connection.syncBudgetRemaining == 3)
        #expect(connection.nextSyncAt != nil)
    }

    @Test func decodesSchedulerFieldsAsNilWhenTheSchedulerIsDisabled() throws {
        let json = """
            { "connections": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "provider": "enable_banking",
              "institution_name": "Revolut",
              "status": "active",
              "consent_state": "active",
              "days_until_expiry": 30,
              "expires_at": "2026-09-01T00:00:00+00:00",
              "created_at": "2026-08-01T09:30:00+00:00",
              "last_synced_at": null,
              "background_sync_enabled": false,
              "sync_budget_remaining": null,
              "next_sync_at": null
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            ConnectionsResponse.self, from: Data(json.utf8)
        )
        let connection = response.connections[0]
        #expect(connection.backgroundSyncEnabled == false)
        #expect(connection.syncBudgetRemaining == nil)
        #expect(connection.nextSyncAt == nil)
    }

    @Test func rejectsMissingBackgroundSyncEnabled() {
        // Unlike syncBudgetRemaining/nextSyncAt (nullable, so a missing key
        // still decodes to nil), backgroundSyncEnabled is non-optional — the
        // backend always sends it, so a missing key is a contract violation
        // that must throw, not silently default (client/CLAUDE.md).
        let json = """
            { "connections": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "provider": "enable_banking",
              "institution_name": "Revolut",
              "status": "active",
              "consent_state": "active",
              "days_until_expiry": 30,
              "expires_at": null,
              "created_at": "2026-08-01T09:30:00+00:00",
              "last_synced_at": null,
              "sync_budget_remaining": null,
              "next_sync_at": null
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(ConnectionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEveryConsentState() throws {
        let cases: [(String, ConsentState)] = [
            ("pending", .pending),
            ("active", .active),
            ("expiring_soon", .expiringSoon),
            ("expired", .expired),
            ("revoked", .revoked),
            ("error", .error),
        ]
        for (raw, expected) in cases {
            let json = Self.envelope(consentState: raw)
            let response = try TraccioCore.jsonDecoder().decode(
                ConnectionsResponse.self, from: Data(json.utf8)
            )
            #expect(response.connections[0].consentState == expected)
        }
    }

    @Test func decodesEveryConnectionStatus() throws {
        let cases: [(String, ConnectionStatus)] = [
            ("pending", .pending),
            ("active", .active),
            ("expired", .expired),
            ("revoked", .revoked),
            ("error", .error),
        ]
        for (raw, expected) in cases {
            let json = Self.envelope(status: raw)
            let response = try TraccioCore.jsonDecoder().decode(
                ConnectionsResponse.self, from: Data(json.utf8)
            )
            #expect(response.connections[0].status == expected)
        }
    }

    @Test func rejectsUnknownConsentState() {
        let json = Self.envelope(consentState: "half_expired")
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(ConnectionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownConnectionStatus() {
        let json = Self.envelope(status: "half_active")
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(ConnectionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesNullExpiryAndSyncFieldsAsNil() throws {
        let json = """
            { "connections": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "provider": "enable_banking",
              "institution_name": "Revolut",
              "status": "pending",
              "consent_state": "pending",
              "days_until_expiry": null,
              "expires_at": null,
              "created_at": "2026-08-01T09:30:00+00:00",
              "last_synced_at": null,
              "background_sync_enabled": false,
              "sync_budget_remaining": null,
              "next_sync_at": null
            } ] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            ConnectionsResponse.self, from: Data(json.utf8)
        )
        let connection = response.connections[0]
        #expect(connection.daysUntilExpiry == nil)
        #expect(connection.expiresAt == nil)
        #expect(connection.lastSyncedAt == nil)
        // `institution_logo` omitted entirely — an optional key decodes to nil.
        #expect(connection.institutionLogo == nil)
    }

    @Test func rejectsMissingRequiredField() {
        // `institution_name` omitted — a non-optional field must actually be
        // present; the optional fields (`days_until_expiry`, `expires_at`,
        // `last_synced_at`, `sync_budget_remaining`, `next_sync_at`) would
        // decode a missing key as `nil` instead.
        let json = """
            { "connections": [ {
              "id": "11111111-1111-1111-1111-111111111111",
              "provider": "enable_banking",
              "status": "active",
              "consent_state": "active",
              "days_until_expiry": 9,
              "expires_at": null,
              "created_at": "2026-08-01T09:30:00+00:00",
              "last_synced_at": null,
              "background_sync_enabled": false,
              "sync_budget_remaining": null,
              "next_sync_at": null
            } ] }
            """
        #expect(throws: DecodingError.self) {
            try TraccioCore.jsonDecoder().decode(ConnectionsResponse.self, from: Data(json.utf8))
        }
    }

    @Test func decodesEmptyConnectionsAsAValidState() throws {
        let json = """
            { "connections": [] }
            """
        let response = try TraccioCore.jsonDecoder().decode(
            ConnectionsResponse.self, from: Data(json.utf8)
        )
        #expect(response.connections.isEmpty)
    }

    /// Build an envelope with `status`/`consentState` substituted, for the
    /// per-case enum tests above.
    private static func envelope(status: String = "active", consentState: String = "active")
        -> String
    {
        """
        { "connections": [ {
          "id": "11111111-1111-1111-1111-111111111111",
          "provider": "enable_banking",
          "institution_name": "Revolut",
          "status": "\(status)",
          "consent_state": "\(consentState)",
          "days_until_expiry": 9,
          "expires_at": "2026-09-01T00:00:00+00:00",
          "created_at": "2026-08-01T09:30:00+00:00",
          "last_synced_at": null,
          "background_sync_enabled": false,
          "sync_budget_remaining": null,
          "next_sync_at": null
        } ] }
        """
    }
}
