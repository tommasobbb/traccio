/// Envelope for the account list returned by `GET /accounts`.
///
/// Mirrors the `AccountsResponse` schema in `docs/api/openapi.json`. A wrapper
/// object rather than a bare array leaves room for pagination or metadata later
/// without breaking decoding.
public struct AccountsResponse: Codable, Sendable {
    /// The caller's accounts, oldest first.
    public let accounts: [AccountResponse]

    public init(accounts: [AccountResponse]) {
        self.accounts = accounts
    }
}
