import SwiftUI
import TraccioCore

/// The "Per conto" card — Task 6's account breakdown, `by_account` finally
/// rendered (closes the loop with ADR 0017: an account's own alias/colour/
/// icon now shows up on the dashboard, not just Conti and Movimenti).
///
/// Flat, unlike `CategoryBreakdownList` — accounts have no hierarchy — and
/// no drill-through: `GET /transactions` has no `account_id` + period
/// combination this card would need beyond what tapping "Per categoria"'s
/// rows or the trend chart's bars already offers, and duplicating that
/// affordance here was judged not worth the row's tap-target ambiguity with
/// scrolling. Renders nothing when there are no accounts to show, same
/// posture as `DashboardView`'s other cards.
struct AccountBreakdownCard: View {
    let accounts: [AccountSummaryResponse]
    let currency: String
    let totalSpending: Int

    var body: some View {
        if !accounts.isEmpty {
            Card {
                EyebrowLabel(text: "Per conto", color: Palette.ink)
                VStack(spacing: 0) {
                    ForEach(accounts, id: \.accountID) { account in
                        accountRow(account)
                        if account.accountID != accounts.last?.accountID {
                            Divider().overlay(Palette.separatorSubtle)
                        }
                    }
                }
            }
        }
    }

    private func accountRow(_ account: AccountSummaryResponse) -> some View {
        HStack(spacing: 10) {
            IconTile(
                systemImage: (account.icon ?? .bank).systemImageName,
                color: account.color ?? .slate,
                diameter: 28
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Spacing.tightGap) {
                    Text(account.accountName ?? "Conto")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    AmountText(
                        amount: account.spending, currencyCode: currency, kind: .spending,
                        font: Typography.caption.weight(.bold)
                    )
                }
                HStack(spacing: Spacing.tightGap) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Palette.neutralFill)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Palette.color(account.color ?? .slate))
                                    .frame(width: proxy.size.width * fillFraction(for: account))
                            }
                    }
                    .frame(height: 4)
                    Text(percentageText(for: account))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// This row's bar length relative to the largest spending among
    /// `accounts` — a layout ratio, not a financial derivation, same class
    /// of computation as `CategoryBreakdownRow.fillFraction`.
    private func fillFraction(for account: AccountSummaryResponse) -> Double {
        let maxSpending = accounts.map(\.spending).max() ?? 0
        return maxSpending > 0 ? Double(account.spending) / Double(maxSpending) : 0
    }

    private func percentageText(for account: AccountSummaryResponse) -> String {
        guard totalSpending > 0 else { return "0%" }
        let percentage = TraccioCore.roundedPercentage(Double(account.spending) / Double(totalSpending))
        return "\(percentage)%"
    }
}
