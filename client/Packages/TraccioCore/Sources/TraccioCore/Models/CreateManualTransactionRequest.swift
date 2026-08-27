import Foundation

/// Body for `POST /transactions` — create a movement on a manual account
/// (ADR 0020).
///
/// Mirrors the `CreateManualTransactionRequest` schema in
/// `docs/api/openapi.json`. Only manual accounts accept this; the backend
/// answers `409 account_not_manual` for a synced one. The new row is always
/// `booked` with `role == .personal`.
///
/// `CodingKeys` spell the wire names explicitly, and `valueDate` encodes
/// through `jsonEncoder()`'s ISO-8601 date strategy — the same shape the
/// decoder accepts.
public struct CreateManualTransactionRequest: Encodable, Sendable {
    /// The manual account the movement belongs to. Must be the caller's and
    /// manual.
    public let accountID: UUID
    /// Signed value in the currency's minor unit (cents): negative for money
    /// out, positive for money in. The backend rejects a non-integer.
    public let amount: Int
    /// ISO 4217 code of `amount`.
    public let currency: String
    /// When the movement affects the balance. `bookedAt` is left `nil` for a
    /// manual row, so every date-bounded query falls back to this.
    public let valueDate: Date
    /// Free-text description the user typed.
    public let description: String
    /// An optional category to confirm on the new row at creation time. Must
    /// be the caller's. Omitted from the payload when `nil`.
    public let confirmedCategoryID: UUID?

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case amount
        case currency
        case valueDate = "value_date"
        case description
        case confirmedCategoryID = "confirmed_category_id"
    }

    public init(
        accountID: UUID,
        amount: Int,
        currency: String,
        valueDate: Date,
        description: String,
        confirmedCategoryID: UUID? = nil
    ) {
        self.accountID = accountID
        self.amount = amount
        self.currency = currency
        self.valueDate = valueDate
        self.description = description
        self.confirmedCategoryID = confirmedCategoryID
    }
}
