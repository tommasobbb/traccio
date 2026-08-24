import SwiftUI
import TraccioCore

/// "Nuovo evento" — the form presented from `EventsView` to create an event.
///
/// No mockup covers this screen (`docs/design/canvas/` has no Eventi
/// artboard), so it is built from existing tokens/components — same posture
/// as `CategoryEditorSheet`. The date range is optional and behind a toggle,
/// since `start_date`/`end_date` are themselves optional on the backend
/// (`docs/domain.md` §Event: "a hint used to suggest membership, not a rule
/// that assigns it").
struct CreateEventSheet: View {
    var isSaving: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the trimmed name and the optional date range once the
    /// user submits a valid form.
    let onSave: (String, CalendarDate?, CalendarDate?) -> Void
    let onCancel: () -> Void

    @State private var nameText = ""
    @State private var includesDateRange = false
    @State private var startDate = Date()
    @State private var endDate = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    Card {
                        EyebrowLabel(text: "Nome")
                        TextField("Es. Turchia 2026", text: $nameText)
                            .font(Typography.statFigure)
                            .foregroundStyle(Palette.ink)
                            .autocorrectionDisabled()
                    }
                    dateRangeCard
                }
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Nuovo evento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea", action: submit)
                        .disabled(isSaving || trimmedName.isEmpty)
                }
            }
        }
    }

    private var dateRangeCard: some View {
        Card {
            Toggle(isOn: $includesDateRange.animation()) {
                EyebrowLabel(text: "Periodo (opzionale)")
            }
            .tint(Palette.accent)
            if includesDateRange {
                DatePicker("Inizio", selection: $startDate, displayedComponents: .date)
                DatePicker("Fine", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
        }
    }

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        let start = includesDateRange ? CalendarDate(date: startDate) : nil
        let end = includesDateRange ? CalendarDate(date: endDate) : nil
        onSave(trimmedName, start, end)
    }
}
