import SwiftUI
import TraccioCore

/// One event row on `EventsView`: name, member count, date range, and the
/// derived net total — following the same row idiom as `RuleRow`/
/// `categoryRow`, wrapped in a `NavigationLink` by the caller.
struct EventRow: View {
    let event: EventResponse

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.name)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 8)
            amountColumn
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.inkQuaternary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 5) {
            if event.status == .closed {
                Badge(text: "Chiuso", style: .neutral)
            }
            Text(memberCountLabel)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            if let dateRangeLabel {
                Text(dateRangeLabel)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private var memberCountLabel: String {
        event.memberCount == 1 ? "1 movimento" : "\(event.memberCount) movimenti"
    }

    /// The date range, formatted for display — `nil` when neither bound is
    /// set, since the range is only ever a hint (`docs/domain.md` §Event).
    private var dateRangeLabel: String? {
        guard let start = event.startDate else { return nil }
        guard let end = event.endDate, end != start else {
            return TraccioCore.formatCalendarDate(start)
        }
        return "\(TraccioCore.formatCalendarDate(start)) – \(TraccioCore.formatCalendarDate(end))"
    }

    @ViewBuilder
    private var amountColumn: some View {
        if let currency = event.currency {
            AmountText(amount: event.total, currencyCode: currency, kind: .net, font: Typography.compactFigure)
        } else {
            Text("—")
                .font(Typography.compactFigure)
                .foregroundStyle(Palette.inkQuaternary)
        }
    }
}
