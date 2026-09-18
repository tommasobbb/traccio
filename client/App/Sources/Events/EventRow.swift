import SwiftUI
import TraccioCore

/// One event row on `EventsView`: name, member count, date range, and the
/// derived net total — following the same row idiom as `RuleRow`/
/// `categoryRow`, wrapped in a `NavigationLink` by the caller.
///
/// The subtitle follows `TransactionRow`'s pattern (`subtitle`/
/// `captionPieces`/`captionText`): every flexible piece collapses into one
/// `Text` with `.lineLimit(1)` rather than several `Text`s sharing an
/// `HStack` with none — the latter was the row's actual bug, not just the
/// date formatter (`docs/design/tokens.md`'s "Text never wraps").
struct EventRow: View {
    let event: EventResponse

    var body: some View {
        HStack(spacing: Spacing.itemGap) {
            EventTile(emoji: event.emoji, color: event.color, diameter: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.name)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                subtitle
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            amountColumn
                .layoutPriority(1)
            DisclosureChevron()
        }
        .rowScrollTransition()
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 5) {
            if event.status == .closed {
                Badge(text: "Chiuso", style: .neutral)
            }
            if !captionText.isEmpty {
                Text(captionText)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var memberCountLabel: String {
        event.memberCount == 1 ? "1 movimento" : "\(event.memberCount) movimenti"
    }

    /// The date range, formatted compactly (e.g. `"10 – 12 set 2026"`) — `nil`
    /// when neither bound is set, since the range is only ever a hint
    /// (`docs/domain.md` §Event).
    private var dateRangeLabel: String? {
        guard let start = event.startDate else { return nil }
        return TraccioCore.formatCalendarDateRange(from: start, to: event.endDate)
    }

    private var captionPieces: [String] {
        [memberCountLabel, dateRangeLabel].compactMap { $0 }
    }

    private var captionText: String {
        captionPieces.joined(separator: " · ")
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
