import SwiftUI
import TraccioCore

/// `TransactionDetailView`'s event card: a chip naming this transaction's
/// event, plus the actions to change it — closes the "assign to event" gap
/// left open when `event_id` first landed on the read model (see
/// `tasks/backlog.md`), which only let a transaction be *added* to an event
/// from the event's own detail screen (`AddEventMembersSheet`). This card is
/// the reverse direction, so unlike the read-only chip it replaced, it
/// renders even without an event.
///
/// The chip is a `NavigationLink` to `EventDetailView` when the event
/// resolved against `events` (the caller's already-fetched list); otherwise
/// a non-navigable row showing a generic label, the same degrade
/// `TransactionRow`'s advance lookup already uses — the backend, not a stale
/// local list, stays the authority on whether the event still exists.
struct TransactionEventCard: View {
    let eventID: UUID?
    /// The caller's events, for resolving `eventID` to a display name and,
    /// when it resolves, a `NavigationLink` to `EventDetailView`.
    let events: [EventResponse]
    /// The client `EventDetailView` reaches the backend through, so
    /// navigating to it shares the caller's connection rather than
    /// defaulting a second one.
    let client: any APIClientProtocol
    /// Shared with the caller so the push zooms from the chip's own frame
    /// instead of sliding in (`docs/decisions/0030-liquid-glass-chrome.md`).
    let transitionNamespace: Namespace.ID
    let isUpdating: Bool
    let onOpenEventPicker: () -> Void
    let onRemoveFromEvent: () -> Void

    var body: some View {
        Card {
            EyebrowLabel(text: "Evento")
            if let eventID {
                if let event = events.first(where: { $0.id == eventID }) {
                    NavigationLink {
                        EventDetailView(event: event, client: client)
                        #if os(iOS)
                        .navigationTransition(.zoom(sourceID: event.id, in: transitionNamespace))
                        #endif
                    } label: {
                        row(event: event, isNavigable: true)
                    }
                    .buttonStyle(.pressableRow)
                    .matchedTransitionSource(id: event.id, in: transitionNamespace)
                } else {
                    row(event: nil, isNavigable: false)
                }
                Divider().overlay(Palette.separator)
                actionRow(title: "Cambia evento", action: onOpenEventPicker)
                actionRow(title: "Rimuovi dall'evento", action: onRemoveFromEvent)
            } else {
                actionRow(title: "Assegna a un evento", action: onOpenEventPicker)
            }
        }
    }

    private func actionRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
    }

    private func row(event: EventResponse?, isNavigable: Bool) -> some View {
        HStack(spacing: Spacing.itemGap) {
            if let event {
                EventTile(emoji: event.emoji, color: event.color, diameter: 32)
            }
            Text(event?.name ?? "Evento")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(isNavigable ? Palette.ink : Palette.inkSecondary)
                .lineLimit(1)
            Spacer()
            if isNavigable {
                DisclosureChevron()
            }
        }
        .contentShape(Rectangle())
    }
}
