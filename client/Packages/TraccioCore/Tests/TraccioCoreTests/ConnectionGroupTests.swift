import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.groupByConnection(connections:accounts:)` — pure
/// grouping logic, no backend involved. Fixtures are synthetic
/// (`.claude/rules/data-safety.md`): invented bank names, round amounts are
/// not even in play here since accounts carry no amount.
struct ConnectionGroupTests {
    private static func connection(id: UUID = UUID(), name: String = "Test Bank")
        -> ConnectionResponse
    {
        ConnectionResponse(
            id: id,
            provider: "enable_banking",
            institutionName: name,
            status: .active,
            consentState: .active,
            daysUntilExpiry: 30,
            expiresAt: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            lastSyncedAt: nil
        )
    }

    private static func account(id: UUID = UUID(), connectionID: UUID) -> AccountResponse {
        AccountResponse(
            id: id,
            connectionID: connectionID,
            kind: .current,
            currency: "EUR",
            name: "Test Current",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func pairsEachConnectionWithItsMatchingAccounts() {
        let revolut = Self.connection(name: "Revolut")
        let isybank = Self.connection(name: "Isybank")
        let revolutAccount = Self.account(connectionID: revolut.id)
        let isybankAccount = Self.account(connectionID: isybank.id)

        let groups = TraccioCore.groupByConnection(
            connections: [revolut, isybank], accounts: [revolutAccount, isybankAccount]
        )

        #expect(groups.count == 2)
        #expect(groups[0].connection?.id == revolut.id)
        #expect(groups[0].accounts == [revolutAccount])
        #expect(groups[1].connection?.id == isybank.id)
        #expect(groups[1].accounts == [isybankAccount])
    }

    @Test func aConnectionWithNoAccountsStillProducesAGroup() {
        let freshlyAuthorized = Self.connection()
        let groups = TraccioCore.groupByConnection(connections: [freshlyAuthorized], accounts: [])

        #expect(groups.count == 1)
        #expect(groups[0].connection?.id == freshlyAuthorized.id)
        #expect(groups[0].accounts.isEmpty)
    }

    @Test func accountsMatchingNoConnectionLandInATrailingOrphanedGroup() {
        let known = Self.connection()
        let knownAccount = Self.account(connectionID: known.id)
        let orphan = Self.account(connectionID: UUID())

        let groups = TraccioCore.groupByConnection(
            connections: [known], accounts: [knownAccount, orphan]
        )

        #expect(groups.count == 2)
        #expect(groups[0].connection?.id == known.id)
        #expect(groups[1].connection == nil)
        #expect(groups[1].accounts == [orphan])
    }

    @Test func returnsNoGroupsForEmptyInput() {
        let groups = TraccioCore.groupByConnection(connections: [], accounts: [])
        #expect(groups.isEmpty)
    }
}
