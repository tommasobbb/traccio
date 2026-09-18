import SwiftUI
import TraccioCore

/// The event picker presented from `TransactionDetailView`'s "Assegna a un
/// evento" / "Cambia evento" rows.
///
/// A sheet rather than an inline list on the transaction's own card
/// (`categoryRow`'s pattern): assigning to an event is an occasional action,
/// unlike categorizing, so a full event list rendered on *every* transaction
/// detail would be permanent noise for a rare gesture.
struct EventPickerSheet: View {
    /// The caller's events, to choose from.
    let events: [EventResponse]
    /// This transaction's current event, if any — renders a checkmark on
    /// that row.
    let selectedEventID: UUID?
    var isUpdating: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the tapped event's id.
    let onSelect: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    eventsCard
                }
                .padding(Spacing.gutter)
            }
            .sheetChrome("Scegli un evento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
            }
        }
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.tightGap) {
            EyebrowLabel(text: "Eventi")
            if events.isEmpty {
                Text("Non hai ancora nessun evento. Puoi crearne uno da Impostazioni → Eventi.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                OptionListCard {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 {
                            Divider().overlay(Palette.separator)
                        }
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: EventResponse) -> some View {
        let isSelected = event.id == selectedEventID
        return OptionRowLayout(
            title: event.name, isSelected: isSelected,
            action: { onSelect(event.id) },
            leading: { EventTile(emoji: event.emoji, color: event.color, diameter: 28) }
        )
        .disabled(isUpdating || isSelected)
    }
}
