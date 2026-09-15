import SwiftUI
import TraccioCore

/// "Nuovo evento" / "Modifica evento" — the one form that both creates an
/// event and edits an existing one (ADR 0027: a single editor, not two
/// action endpoints).
///
/// No mockup covers this screen (`docs/design/canvas/` has no Eventi
/// artboard), so it is built from existing tokens/components — the colour
/// grid is lifted from `AccountEditorSheet`. The emoji picker is a curated
/// grid plus a free-text field, so any emoji the keyboard can produce is
/// accepted (the backend validates it is a single emoji).
struct EventEditorSheet: View {
    /// The event being edited, or `nil` to create a new one.
    let existing: EventResponse?
    var isSaving: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the chosen values once the user submits a valid form.
    /// `emoji` is `nil` when none is selected.
    let onSave: (_ name: String, _ emoji: String?, _ color: PaletteColor?, _ start: CalendarDate?, _ end: CalendarDate?) -> Void
    let onCancel: () -> Void

    @State private var nameText: String
    @State private var emoji: String?
    @State private var emojiFieldText: String
    @State private var color: PaletteColor?
    @State private var includesDateRange: Bool
    @State private var startDate: Date
    @State private var endDate: Date

    /// A small, food-and-travel-leaning set covering the events people
    /// actually create (`docs/domain.md`'s "trip, renovation, wedding"); the
    /// free-text field below handles everything else.
    private static let suggestedEmoji = [
        "✈️", "🏖️", "🏔️", "🏝️", "🗺️", "🎒",
        "🏠", "🔨", "🛋️", "🪴", "🚗", "⛽️",
        "💍", "🎉", "🎂", "🎁", "🍽️", "🍷",
        "⚽️", "🎿", "🎸", "📚", "🐶", "💻",
    ]

    init(
        existing: EventResponse? = nil,
        isSaving: Bool,
        failureMessage: String? = nil,
        onSave: @escaping (String, String?, PaletteColor?, CalendarDate?, CalendarDate?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existing = existing
        self.isSaving = isSaving
        self.failureMessage = failureMessage
        self.onSave = onSave
        self.onCancel = onCancel
        _nameText = State(initialValue: existing?.name ?? "")
        _emoji = State(initialValue: existing?.emoji)
        _emojiFieldText = State(initialValue: existing?.emoji ?? "")
        _color = State(initialValue: existing?.color)
        let start = existing?.startDate?.date(calendar: .current)
        let end = existing?.endDate?.date(calendar: .current)
        _includesDateRange = State(initialValue: start != nil || end != nil)
        _startDate = State(initialValue: start ?? Date())
        _endDate = State(initialValue: end ?? start ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    nameCard
                    emojiCard
                    colorCard
                    dateRangeCard
                }
                .padding(Spacing.gutter)
            }
            .sheetChrome(existing == nil ? "Nuovo evento" : "Modifica evento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Crea" : "Salva", action: submit)
                        .disabled(isSaving || trimmedName.isEmpty)
                }
            }
        }
    }

    private var nameCard: some View {
        Card {
            HStack(spacing: 12) {
                EventTile(emoji: emoji, color: color, diameter: 44)
                TextField("Es. Turchia 2026", text: $nameText)
                    .font(Typography.statFigure)
                    .foregroundStyle(Palette.ink)
                    .autocorrectionDisabled()
            }
        }
    }

    private var emojiCard: some View {
        Card {
            HStack {
                EyebrowLabel(text: "Emoji")
                Spacer()
                if emoji != nil {
                    Button("Rimuovi") {
                        emoji = nil
                        emojiFieldText = ""
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.accent)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Self.suggestedEmoji, id: \.self) { candidate in
                    Button {
                        emoji = candidate
                        emojiFieldText = candidate
                    } label: {
                        Text(candidate)
                            .font(.system(size: 22))
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                    .fill(candidate == emoji ? Palette.accentTint : Palette.neutralFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                    .strokeBorder(Palette.accent, lineWidth: candidate == emoji ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Emoji \(candidate)")
                    .accessibilityAddTraits(candidate == emoji ? .isSelected : [])
                }
            }
            Divider().overlay(Palette.separator)
            TextField("Oppure incolla un'emoji", text: $emojiFieldText)
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .autocorrectionDisabled()
                .onChange(of: emojiFieldText) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    emoji = trimmed.isEmpty ? nil : trimmed
                }
        }
    }

    private var colorCard: some View {
        Card {
            HStack {
                EyebrowLabel(text: "Colore")
                Spacer()
                if color != nil {
                    Button("Rimuovi") { color = nil }
                        .font(Typography.caption)
                        .foregroundStyle(Palette.accent)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(PaletteColor.allCases, id: \.self) { candidate in
                    Button {
                        color = candidate
                    } label: {
                        Circle()
                            .fill(Palette.color(candidate))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(Palette.ink, lineWidth: candidate == color ? 2 : 0)
                                    .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.rawValue)
                    .accessibilityAddTraits(candidate == color ? .isSelected : [])
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
                VStack(alignment: .leading, spacing: 4) {
                    EyebrowLabel(text: "Inizio")
                    DatePicker("Inizio", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    EyebrowLabel(text: "Fine")
                    DatePicker("Fine", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
    }

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        let trimmedEmoji = emoji?.trimmingCharacters(in: .whitespaces)
        let start = includesDateRange ? CalendarDate(date: startDate) : nil
        let end = includesDateRange ? CalendarDate(date: endDate) : nil
        onSave(
            trimmedName,
            (trimmedEmoji?.isEmpty ?? true) ? nil : trimmedEmoji,
            color,
            start,
            end
        )
    }
}
