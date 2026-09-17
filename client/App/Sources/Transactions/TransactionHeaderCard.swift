import SwiftUI
import TraccioCore

/// The one `.raised` (glass, `docs/decisions/0032-glass-on-raised-cards.md`)
/// surface on `TransactionDetailView`, matching `EventDetailView`'s own
/// header — a real inconsistency the 2026-09-15 coherence pass found: this
/// header used to render as bare text with no card at all.
struct TransactionHeaderCard: View {
    let transaction: TransactionResponse
    /// The effective category's display name, resolved by the caller against
    /// its own `categories` list — `nil` when there is none yet.
    let categoryName: String?
    /// This transaction's account, for the subtitle's currency/account line.
    /// Best-effort, so `nil` degrades to a generic label rather than hiding
    /// the header.
    let account: AccountResponse?

    var body: some View {
        Card(elevation: .raised) {
            if let categoryName {
                HStack(spacing: 6) {
                    Badge(text: categoryName, style: .neutral)
                    // A rule-generated suggestion must not render like an
                    // explicit user confirmation, now that `POST
                    // /rules/apply` can produce one.
                    if transaction.confirmedCategoryID == nil {
                        Badge(text: "Suggerita", style: .neutral)
                    }
                }
            }
            Text(transaction.displayDescription ?? transaction.description)
                .font(Typography.statFigure)
                .foregroundStyle(Palette.ink)
            Text(subtitle)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private var subtitle: String {
        let dateTime = transaction.effectiveDate.map { date -> String in
            TraccioCore.formatDate(date, style: .dayMonthYearTime)
        }
        let accountLabel = "\(account?.name ?? "Conto") \(transaction.currency)"
        return [dateTime, accountLabel].compactMap { $0 }.joined(separator: " · ")
    }
}
