import Foundation

/// A suggested tracking start (ADR 0024) plus the per-account first-movement
/// dates it is derived from, from `GET /settings/tracking-start/suggestion`.
///
/// Mirrors the `TrackingStartSuggestionResponse` schema in
/// `docs/api/openapi.json`.
public struct TrackingStartSuggestionResponse: Codable, Sendable, Equatable {
    /// The first day of the earliest month every account fully covers, or
    /// `nil` when no account has a dated movement yet.
    public let suggestion: CalendarDate?
    /// The account whose first movement is the latest — the one that pushes
    /// the suggestion forward. `nil` when there is nothing to suggest from.
    public let constrainingAccountID: UUID?
    /// Every account, earliest-movement first (accounts with none last).
    public let accounts: [AccountEarliestResponse]

    private enum CodingKeys: String, CodingKey {
        case suggestion
        case constrainingAccountID = "constraining_account_id"
        case accounts
    }

    public init(
        suggestion: CalendarDate?,
        constrainingAccountID: UUID?,
        accounts: [AccountEarliestResponse]
    ) {
        self.suggestion = suggestion
        self.constrainingAccountID = constrainingAccountID
        self.accounts = accounts
    }
}

/// One account and the date of its earliest movement.
///
/// Mirrors the `AccountEarliestResponse` schema.
public struct AccountEarliestResponse: Codable, Sendable, Equatable, Identifiable {
    /// The account.
    public let accountID: UUID
    /// Its resolved display name (alias, else provider name, else `nil`).
    public let displayName: String?
    /// The date of its first dated movement, or `nil` when it has none — such
    /// an account places no constraint on the suggestion.
    public let earliest: CalendarDate?

    public var id: UUID { accountID }

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case displayName = "display_name"
        case earliest
    }

    public init(accountID: UUID, displayName: String?, earliest: CalendarDate?) {
        self.accountID = accountID
        self.displayName = displayName
        self.earliest = earliest
    }
}
