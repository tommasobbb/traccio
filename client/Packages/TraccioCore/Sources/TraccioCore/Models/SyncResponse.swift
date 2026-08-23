/// The outcome of syncing a connection, from `POST /connections/{id}/sync`.
///
/// Mirrors the `SyncResponse` schema in `docs/api/openapi.json`. Only counts
/// are returned, never account or transaction contents
/// (`.claude/rules/data-safety.md`); the data itself is read back via the
/// resource endpoints (`GET /accounts`, `GET /transactions`).
public struct SyncResponse: Codable, Sendable, Equatable {
    /// How many accounts were discovered and persisted.
    public let accountsSynced: Int
    /// How many transactions were fetched and persisted across those accounts.
    public let transactionsSynced: Int

    private enum CodingKeys: String, CodingKey {
        case accountsSynced = "accounts_synced"
        case transactionsSynced = "transactions_synced"
    }

    public init(accountsSynced: Int, transactionsSynced: Int) {
        self.accountsSynced = accountsSynced
        self.transactionsSynced = transactionsSynced
    }
}
