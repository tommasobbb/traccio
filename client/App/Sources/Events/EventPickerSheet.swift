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
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    eventsCard
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Scegli un evento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
            }
        }
    }

    private var eventsCard: some View {
        Card {
            EyebrowLabel(text: "Eventi")
            if events.isEmpty {
                Text("Non hai ancora nessun evento. Puoi crearne uno da Impostazioni → Eventi.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        eventRow(event)
                        if event.id != events.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ event: EventResponse) -> some View {
        let isSelected = event.id == selectedEventID
        return Button {
            onSelect(event.id)
        } label: {
            HStack(spacing: 12) {
                EventTile(emoji: event.emoji, color: event.color, diameter: 32)
                Text(event.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating || isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
