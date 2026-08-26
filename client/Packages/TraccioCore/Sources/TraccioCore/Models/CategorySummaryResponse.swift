import Foundation

/// One child category's totals, nested inside a `CategoryGroupSummaryResponse`.
///
/// Mirrors the `CategorySummaryResponse` schema in `docs/api/openapi.json`.
/// Unlike before ADR 0018's hierarchy landed in the dashboard
/// (`docs/decisions/0007-dashboard-aggregation.md`'s third revision),
/// `categoryID` is never `nil` here — the "no category" bucket lives one
/// level up, as `CategoryGroupSummaryResponse.categoryID == nil`.
public struct CategorySummaryResponse: Codable, Sendable, Equatable {
    /// The child category's id.
    public let categoryID: UUID
    /// The child's current name, resolved by the backend at read time. `nil`
    /// only in the rare race where the category was deleted between
    /// aggregation and this read.
    public let categoryName: String?
    /// The child's colour, or `nil` in the same rare race as `categoryName`.
    public let color: PaletteColor?
    /// The child's icon, or `nil` if unset (or the same race).
    public let icon: CategoryIcon?
    /// Total spending on this child, a non-negative magnitude, minor units.
    public let spending: Int
    /// Total income on this child, a non-negative magnitude, minor units.
    public let income: Int
    /// Count of transactions carrying this child category, including
    /// zero-`effective_amount` ones (transfers, reimbursements).
    public let transactionCount: Int

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
        case color
        case icon
        case spending
        case income
        case transactionCount = "transaction_count"
    }

    public init(
        categoryID: UUID, categoryName: String?, color: PaletteColor?, icon: CategoryIcon?,
        spending: Int, income: Int, transactionCount: Int
    ) {
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.color = color
        self.icon = icon
        self.spending = spending
        self.income = income
        self.transactionCount = transactionCount
    }
}
