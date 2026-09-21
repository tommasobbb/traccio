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
///
/// **Revised 2026-09-19**: the name moved to a full-width line of its own,
/// above the subtitle/amount line, instead of sharing a row with the amount.
/// The old anatomy gave the amount `.layoutPriority(1)` against the title
/// block's `.layoutPriority(0)` — the title was the one thing that had to
/// give, which meant "Amsterdam 2026" truncated the moment its subtitle
/// ("N movimenti · date range") was wide enough to set the block's width.
/// No `.layoutPriority` is needed now that the name has its own line; the
/// chevron is gone too — a two-line block would center it awkwardly, and
/// `TransactionRow`'s equivalent row has no chevron either, relying on
/// `.pressableRow` + the zoom transition for the tap affordance.
///
/// **Tile enlarged 2026-09-19 (second pass)**: on-device, the two-line
/// anatomy above still read as cramped — the tile stayed at `Transaction
/// Row`'s 44pt even though this row has none of that row's competing
/// elements (no chevron, no third caption). Diameter 44 → 56, matching the
/// row's own vertical padding move in `EventsView.eventListCard` (`6` →
/// `Spacing.itemGap`, then `12` → `16` here) — both `EventTile`/`IconTile`
/// scale their glyph proportionally to `diameter`, so this is a pure size
/// increase, not a re-balance.
struct EventRow: View {
    let event: EventResponse

    var body: some View {
        HStack(spacing: Spacing.itemGap) {
            EventTile(emoji: event.emoji, color: event.color, diameter: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.name)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    subtitle
                    Spacer(minLength: Spacing.tightGap)
                    amountColumn
                }
            }
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
