import Foundation

/// The filters `GET /transactions` accepts, as one value rather than three
/// loose optionals.
///
/// Server-side only: `TransactionsView`'s account/category chips narrow what
/// the backend returns, never what a client-held page shows — filtering a
/// single already-fetched page would silently disagree with the rest of the
/// list on the server (`docs/engineering.md`, "make illegal states
/// unrepresentable").
///
/// `category` is its own three-state enum, not an `Int?`/`Bool` pair, so
/// "a specific category" and "no category at all" are mutually exclusive by
/// construction — the backend's own `422 conflicting_category_filter` exists
/// only because its two query parameters *can* both be set; this type makes
/// that combination unrepresentable on the client instead of merely rejected.
public struct TransactionFilter: Sendable, Equatable {
    /// How the effective category should narrow the result.
    public enum CategoryFilter: Sendable, Equatable {
        /// No category filtering — every transaction, categorized or not.
        case any
        /// Only transactions with no effective category.
        case uncategorized
        /// Only transactions whose effective category is this one.
        case some(UUID)
    }

    /// Restrict to one account, or `nil` for every account.
    public var accountID: UUID?
    /// Restrict to one event's members, or `nil` for no event filtering.
    public var eventID: UUID?
    /// How to narrow by effective category.
    public var category: CategoryFilter
    /// Free-text search term, matched server-side against a transaction's
    /// description (`GET /transactions`'s `q`). `nil` or blank means no
    /// search filtering — the caller is not required to pre-trim, but a
    /// blank string is sent as `nil` in `queryItems` since the backend treats
    /// them identically anyway.
    public var searchTerm: String?
    /// Inclusive lower bound on the same period expression
    /// `GET /dashboard/summary` filters on, or `nil` for no lower bound.
    public var start: Date?
    /// Exclusive upper bound (half-open `[start, end)`), or `nil` for no
    /// upper bound.
    public var end: Date?

    /// No filtering at all — every transaction the caller can see.
    public static let none = TransactionFilter(
        accountID: nil, eventID: nil, category: .any, searchTerm: nil, start: nil, end: nil
    )

    public init(
        accountID: UUID? = nil,
        eventID: UUID? = nil,
        category: CategoryFilter = .any,
        searchTerm: String? = nil,
        start: Date? = nil,
        end: Date? = nil
    ) {
        self.accountID = accountID
        self.eventID = eventID
        self.category = category
        self.searchTerm = searchTerm
        self.start = start
        self.end = end
    }

    /// The query items `GET /transactions` expects for this filter.
    ///
    /// Pure and independently testable: `APIClient.transactions(filter:limit:offset:)`
    /// appends this to its own `limit`/`offset` items rather than building
    /// the query string itself.
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let accountID {
            items.append(URLQueryItem(name: "account_id", value: accountID.uuidString))
        }
        if let eventID {
            items.append(URLQueryItem(name: "event_id", value: eventID.uuidString))
        }
        switch category {
        case .any:
            break
        case .uncategorized:
            items.append(URLQueryItem(name: "uncategorized", value: "true"))
        case .some(let categoryID):
            items.append(URLQueryItem(name: "category_id", value: categoryID.uuidString))
        }
        if let searchTerm, !searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "q", value: searchTerm))
        }
        if let start {
            items.append(URLQueryItem(name: "start", value: TraccioCore.iso8601String(from: start)))
        }
        if let end {
            items.append(URLQueryItem(name: "end", value: TraccioCore.iso8601String(from: end)))
        }
        return items
    }
}
