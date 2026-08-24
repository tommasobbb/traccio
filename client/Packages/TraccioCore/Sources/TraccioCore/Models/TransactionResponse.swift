import Foundation

/// One transaction as returned by `GET /transactions`.
///
/// Mirrors the `TransactionResponse` schema in `docs/api/openapi.json` — a
/// narrow projection of the backend's domain `Transaction`: `user_id`
/// (implied by the caller) and the deduplication internals
/// (`entry_reference`, `stable_key`, `key_strategy`) are omitted by the
/// backend and so are absent here too.
///
/// `amount` is what the bank reported, in the currency's minor unit (cents);
/// negative means outgoing. `effective_amount` is how much actually counts as
/// personal spending — derived from `role` and `status` on the backend (see
/// `docs/architecture.md`) — and is the figure every total should be built
/// from. The client never recomputes it.
///
/// `CodingKeys` map the backend's snake_case wire names to Swift camelCase,
/// following `AccountResponse`'s convention: a backend field rename surfaces
/// as a decode-test failure, not a silent `nil`.
public struct TransactionResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable transaction identifier.
    public let id: UUID
    /// Account this movement belongs to.
    public let accountID: UUID
    /// What the bank reported, in minor units; negative means outgoing. Used
    /// only for balance reconciliation, never rendered as "the" amount.
    public let amount: Int
    /// How much counts as real personal spending, in the same `currency` as
    /// `amount`. Every total the client renders is built from this field.
    public let effectiveAmount: Int
    /// ISO 4217 code of both `amount` and `effectiveAmount`.
    public let currency: String
    /// Settlement time; `nil` while pending.
    public let bookedAt: Date?
    /// When the movement affects the balance.
    public let valueDate: Date?
    /// Raw text from the bank, preserved verbatim.
    public let description: String
    /// Cleaned-up description, produced separately; `nil` until built (no
    /// code path populates it yet — see `docs/decisions/0005-categorization-rules.md`
    /// "Revisit when").
    public let displayDescription: String?
    public let status: TransactionStatus
    public let role: TransactionRole
    /// Written by the categorization rules engine, overwritten freely on
    /// every re-run.
    public let suggestedCategoryID: UUID?
    /// Set only by explicit user action; never by automation.
    public let confirmedCategoryID: UUID?
    /// The category that actually applies: `confirmed` if set, else
    /// `suggested`, else `nil`. The client renders this and never
    /// re-implements the fallback.
    public let effectiveCategoryID: UUID?
    /// The event this transaction is currently grouped under, or `nil`. A
    /// display join resolved by the backend router, not a domain field — see
    /// `docs/domain.md` §Event. The client resolves the event's name
    /// separately (via `GET /events`), the same pattern already used for
    /// `effectiveCategoryID`'s name.
    public let eventID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case amount
        case effectiveAmount = "effective_amount"
        case currency
        case bookedAt = "booked_at"
        case valueDate = "value_date"
        case description
        case displayDescription = "display_description"
        case status
        case role
        case suggestedCategoryID = "suggested_category_id"
        case confirmedCategoryID = "confirmed_category_id"
        case effectiveCategoryID = "effective_category_id"
        case eventID = "event_id"
    }

    public init(
        id: UUID,
        accountID: UUID,
        amount: Int,
        effectiveAmount: Int,
        currency: String,
        bookedAt: Date?,
        valueDate: Date?,
        description: String,
        displayDescription: String?,
        status: TransactionStatus,
        role: TransactionRole,
        suggestedCategoryID: UUID?,
        confirmedCategoryID: UUID?,
        effectiveCategoryID: UUID?,
        eventID: UUID?
    ) {
        self.id = id
        self.accountID = accountID
        self.amount = amount
        self.effectiveAmount = effectiveAmount
        self.currency = currency
        self.bookedAt = bookedAt
        self.valueDate = valueDate
        self.description = description
        self.displayDescription = displayDescription
        self.status = status
        self.role = role
        self.suggestedCategoryID = suggestedCategoryID
        self.confirmedCategoryID = confirmedCategoryID
        self.effectiveCategoryID = effectiveCategoryID
        self.eventID = eventID
    }
}
