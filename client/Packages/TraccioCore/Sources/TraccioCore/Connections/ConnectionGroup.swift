import Foundation

/// One bank connection paired with the accounts it currently exposes, as
/// produced by `groupByConnection(connections:accounts:)`.
///
/// `connection` is `nil` only for the single trailing group of accounts
/// matching no connection in the input — an account should always resolve to
/// one, but a group that silently dropped orphaned accounts would hide a
/// real data inconsistency rather than surface it.
public struct ConnectionGroup: Sendable, Equatable {
    public let connection: ConnectionResponse?
    public let accounts: [AccountResponse]

    public init(connection: ConnectionResponse?, accounts: [AccountResponse]) {
        self.connection = connection
        self.accounts = accounts
    }
}

extension TraccioCore {
    /// Pair each connection with the accounts it exposes.
    ///
    /// Pure and order-preserving: does not sort — `connections` is expected
    /// in the order `GET /connections` returns — it only attaches each
    /// connection's matching accounts (by `AccountResponse.connectionID`) in
    /// their given order. Every connection appears even with zero accounts
    /// (a freshly-authorized consent before its first sync is still worth
    /// rendering, per `docs/design/canvas/Accounts.dc.html`). Accounts
    /// matching no connection in `connections` are collected into one
    /// trailing group with a `nil` connection, mirroring `groupByDay`'s
    /// undated-group precedent, rather than being silently dropped.
    ///
    /// Parameters
    /// ----------
    /// connections:
    ///     Connections in display order.
    /// accounts:
    ///     Accounts to distribute across them.
    ///
    /// Returns
    /// -------
    /// One group per connection, in input order, followed by the orphaned
    /// group (if any) last.
    public static func groupByConnection(
        connections: [ConnectionResponse],
        accounts: [AccountResponse]
    ) -> [ConnectionGroup] {
        var accountsByConnection: [UUID: [AccountResponse]] = [:]
        var orphaned: [AccountResponse] = []
        for account in accounts {
            if connections.contains(where: { $0.id == account.connectionID }) {
                accountsByConnection[account.connectionID, default: []].append(account)
            } else {
                orphaned.append(account)
            }
        }

        var groups = connections.map { connection in
            ConnectionGroup(
                connection: connection, accounts: accountsByConnection[connection.id] ?? []
            )
        }
        if !orphaned.isEmpty {
            groups.append(ConnectionGroup(connection: nil, accounts: orphaned))
        }
        return groups
    }
}
