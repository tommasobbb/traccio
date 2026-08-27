import Foundation

/// Body for `POST /transactions/{id}/edit` — edit a movement on a manual
/// account (ADR 0020).
///
/// Mirrors the `EditManualTransactionRequest` schema in
/// `docs/api/openapi.json`: the same movement fields as
/// `CreateManualTransactionRequest` minus `account_id` (a movement does not
/// move between accounts) and the category (`POST`/`DELETE
/// /transactions/{id}/category` own that). The backend answers `409
/// transaction_not_manual` if the row is on a synced account.
public struct EditManualTransactionRequest: Encodable, Sendable {
    /// New signed value in minor units.
    public let amount: Int
    /// New ISO 4217 code of `amount`.
    public let currency: String
    /// New value date.
    public let valueDate: Date
    /// New description text.
    public let description: String

    private enum CodingKeys: String, CodingKey {
        case amount
        case currency
        case valueDate = "value_date"
        case description
    }

    public init(amount: Int, currency: String, valueDate: Date, description: String) {
        self.amount = amount
        self.currency = currency
        self.valueDate = valueDate
        self.description = description
    }
}
