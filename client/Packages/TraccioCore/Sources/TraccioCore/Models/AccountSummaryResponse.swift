import Foundation

/// Spending and income totals for one account, within one currency, as
/// returned by `GET /dashboard/summary`.
///
/// Mirrors the `AccountSummaryResponse` schema in `docs/api/openapi.json` —
/// new in `docs/decisions/0007-dashboard-aggregation.md`'s third revision,
/// closing the loop with ADR 0017 (accounts finally show up in the
/// dashboard, not just the category breakdown).
public struct AccountSummaryResponse: Codable, Sendable, Equatable {
    /// The account these totals belong to.
    public let accountID: UUID
    /// The account's resolved display name, or `nil` if unset or the account
    /// was deleted between aggregation and this read.
    public let accountName: String?
    /// The account's colour, or `nil` if unset (or the same race).
    public let color: PaletteColor?
    /// The account's icon, or `nil` if unset (or the same race).
    public let icon: AccountIcon?
    /// Total spending on this account, a non-negative magnitude, minor units.
    public let spending: Int
    /// Total income on this account, a non-negative magnitude, minor units.
    public let income: Int
    /// Count of transactions on this account, including zero-`effective_amount`
    /// ones (transfers, reimbursements).
    public let transactionCount: Int

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case accountName = "account_name"
        case color
        case icon
        case spending
        case income
        case transactionCount = "transaction_count"
    }

    public init(
        accountID: UUID, accountName: String?, color: PaletteColor?, icon: AccountIcon?,
        spending: Int, income: Int, transactionCount: Int
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.color = color
        self.icon = icon
        self.spending = spending
        self.income = income
        self.transactionCount = transactionCount
    }
}
