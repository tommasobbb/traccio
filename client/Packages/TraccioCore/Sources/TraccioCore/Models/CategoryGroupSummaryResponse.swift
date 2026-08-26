import Foundation

/// One category root's totals, its children rolled up, as returned by
/// `GET /dashboard/summary`.
///
/// Mirrors the `CategoryGroupSummaryResponse` schema in
/// `docs/api/openapi.json` — the root type of `by_category`
/// (`docs/decisions/0007-dashboard-aggregation.md`'s third revision, ADR
/// 0018's hierarchy landing in the dashboard). `spending`/`income`/
/// `transactionCount` are a **rollup**: this root's own totals plus every
/// child's; `direct*` are the root's own transactions only, excluding any
/// child — `spending == directSpending + children.map(\.spending).reduce(0,
/// +)` always holds, enforced server-side.
public struct CategoryGroupSummaryResponse: Codable, Sendable, Equatable {
    /// The root category's id, or `nil` for the "no category" bucket — a
    /// real, counted entry with no children, never omitted.
    public let categoryID: UUID?
    /// The root's current name, resolved by the backend at read time. `nil`
    /// iff `categoryID` is `nil`.
    public let categoryName: String?
    /// The root's colour, or `nil` iff `categoryID` is `nil`.
    public let color: PaletteColor?
    /// The root's icon, or `nil` if unset (or `categoryID` is `nil`).
    public let icon: CategoryIcon?
    /// Total spending, including every child, a non-negative magnitude,
    /// minor units.
    public let spending: Int
    /// Total income, including every child, a non-negative magnitude, minor
    /// units.
    public let income: Int
    /// Total transaction count, including every child.
    public let transactionCount: Int
    /// Spending from transactions on the root itself, excluding any child.
    public let directSpending: Int
    /// Income from transactions on the root itself, excluding any child.
    public let directIncome: Int
    /// Transaction count on the root itself, excluding any child.
    public let directTransactionCount: Int
    /// This root's children with at least one transaction, sorted by
    /// spending then income descending.
    public let children: [CategorySummaryResponse]

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
        case color
        case icon
        case spending
        case income
        case transactionCount = "transaction_count"
        case directSpending = "direct_spending"
        case directIncome = "direct_income"
        case directTransactionCount = "direct_transaction_count"
        case children
    }

    public init(
        categoryID: UUID?, categoryName: String?, color: PaletteColor?, icon: CategoryIcon?,
        spending: Int, income: Int, transactionCount: Int, directSpending: Int, directIncome: Int,
        directTransactionCount: Int, children: [CategorySummaryResponse] = []
    ) {
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.color = color
        self.icon = icon
        self.spending = spending
        self.income = income
        self.transactionCount = transactionCount
        self.directSpending = directSpending
        self.directIncome = directIncome
        self.directTransactionCount = directTransactionCount
        self.children = children
    }
}
