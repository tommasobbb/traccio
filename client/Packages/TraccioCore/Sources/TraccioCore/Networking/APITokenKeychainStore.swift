import Foundation
import Security

/// Persists a single secret in the system Keychain — the seam `ServerConfigurationStore`
/// depends on, so a test can inject an in-memory fake instead of touching the
/// real Keychain (`.claude/rules/swift.md`'s "protocols at real seams").
///
/// This is the app's *own* shared API secret (ADR 0014), not a bank
/// credential — `client/CLAUDE.md`'s "the client has no notion that [bank]
/// tokens exist" is unrelated and still holds.
public protocol APITokenStoring: Sendable {
    /// The stored token, or `nil` if none is saved.
    func load() -> String?
    /// Save `token`, replacing any previously stored value.
    func save(_ token: String)
    /// Remove any stored token.
    func delete()
}

/// The production `APITokenStoring`: a single generic-password Keychain item.
public struct KeychainAPITokenStore: APITokenStoring {
    private let service: String
    private let account: String

    /// Create a store.
    ///
    /// Parameters
    /// ----------
    /// service:
    ///     The Keychain item's `kSecAttrService`. Defaults to a value scoped
    ///     to this app so it can't collide with another app's item.
    /// account:
    ///     The Keychain item's `kSecAttrAccount`. Traccio is single-user, so
    ///     a fixed constant is enough — no per-user namespacing needed.
    public init(service: String = "com.traccio.apiToken", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        // Try an update first — SecItemAdd fails on an item that already
        // exists, and this store never needs to know in advance which case
        // it's in.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
