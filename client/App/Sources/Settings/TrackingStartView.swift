import SwiftUI
import TraccioCore

/// "Inizio tracciamento" — the screen where the user picks the day the
/// dashboard and Movimenti begin from (ADR 0024).
///
/// Fase B redesign (`docs/design/canvas/TrackingStart.dc.html`): one
/// question — "Da quando vuoi contare?" — a per-account timeline showing
/// when each account's data starts and where the floor falls, and one
/// primary action (use the suggested date), with "choose another date" and
/// "show everything" as secondary paths. Replaces the old stack of four
/// cards and two separate save buttons.
struct TrackingStartView: View {
    @State private var model: TrackingStartViewModel
    @State private var pickedDate = Date()
    @State private var pickerSeeded = false
    @State private var isPickingDate = false

    init(model: TrackingStartViewModel = TrackingStartViewModel()) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                switch model.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                case .failed:
                    EmptyState(
                        systemImage: "wifi.slash",
                        title: "Impossibile caricare",
                        description: "Verifica che il backend sia in esecuzione, poi riprova.",
                        tone: .warning,
                        actionTitle: "Riprova",
                        action: { Task { await model.load() } }
                    )
                case .loaded(let current, let suggestion):
                    loaded(current: current, suggestion: suggestion)
                }
            }
            .padding(Spacing.gutter)
        }
        .screenBackground()
        .navigationTitle("Inizio tracciamento")
        .task { await model.load() }
    }

    // MARK: Loaded

    @ViewBuilder
    private func loaded(
        current: CalendarDate?, suggestion: TrackingStartSuggestionResponse
    ) -> some View {
        let timeline = TraccioCore.trackingTimeline(
            suggestion: suggestion,
            current: current,
            now: CalendarDate(date: Date())
        )

        Text("Da quando vuoi contare?")
            .font(.title2)
            .fontWeight(.bold)
            .foregroundStyle(Palette.ink)

        Text(
            "La Panoramica e i Movimenti mostrano solo ciò che è successo da questa data in poi. Prima di qui i mesi hanno i dati solo di alcuni conti, quindi i totali ingannano. Cambiarla non cancella nulla."
        )
        .font(Typography.caption)
        .foregroundStyle(Palette.inkSecondary)

        Card {
            EyebrowLabel(text: "I tuoi conti")
            timelinePlot(timeline)
            Divider().overlay(Palette.separator)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Conteggio da")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
                Text(
                    current.map { TraccioCore.formatCalendarDate($0) }
                        ?? "tutti i movimenti"
                )
                .font(Typography.statFigure)
                .foregroundStyle(Palette.ink)
            }
        }

        actions(current: current, suggestion: suggestion)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(
        current: CalendarDate?, suggestion: TrackingStartSuggestionResponse
    ) -> some View {
        VStack(spacing: 10) {
            if let suggested = suggestion.suggestion {
                primaryButton(
                    "Usa il \(TraccioCore.formatCalendarDate(suggested))",
                    disabled: current == suggested
                ) {
                    Task { await model.save(suggested) }
                }
            }

            secondaryButton(isPickingDate ? "Nascondi il calendario" : "Scegli un'altra data") {
                if !pickerSeeded {
                    pickerSeeded = true
                    if let seed = (current ?? suggestion.suggestion)?.date() {
                        pickedDate = seed
                    }
                }
                withAnimation(.easeInOut(duration: 0.2)) { isPickingDate.toggle() }
            }

            if isPickingDate {
                VStack(spacing: 10) {
                    DatePicker(
                        "Inizio tracciamento", selection: $pickedDate, displayedComponents: .date
                    )
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)

                    primaryButton("Salva questa data") {
                        Task { await model.save(CalendarDate(date: pickedDate)) }
                    }
                }
                .padding(14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(Palette.separatorSubtle)
                )
            }

            if current != nil {
                Button {
                    Task { await model.save(nil) }
                } label: {
                    Text("Mostra tutti i movimenti, dall'inizio")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.warning)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(model.isSaving)
            }

            if model.saveFailed {
                Text("Non è stato possibile salvare. Riprova.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
            }
        }
    }

    private func primaryButton(
        _ title: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if model.isSaving {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(title).font(Typography.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                (disabled || model.isSaving) ? Palette.accentPressed : Palette.accent,
                in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            )
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled || model.isSaving)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Palette.card,
                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.3))
                )
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
    }

    // MARK: Timeline

    @ViewBuilder
    private func timelinePlot(_ timeline: TrackingTimeline) -> some View {
        if timeline.bars.isEmpty {
            Text("Nessun conto.")
                .font(Typography.body)
                .foregroundStyle(Palette.inkSecondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let start = timeline.axisStart {
                    HStack {
                        Text(monthYear(start))
                        Spacer()
                        Text("adesso")
                    }
                    .font(Typography.eyebrow)
                    .foregroundStyle(Palette.inkQuaternary)
                }

                // No GeometryReader / reserved height: each row is
                // fixed-height and the stack sizes itself, so the plot can
                // never overflow onto the divider and the "Conteggio da" row
                // below (which a hardcoded `rowHeight` guess did from ~5
                // accounts up). The per-bar width is taken locally, inside
                // each capsule's own overlay.
                VStack(spacing: 16) {
                    ForEach(timeline.bars) { bar in
                        barRow(bar)
                    }
                }
            }
        }
    }

    private func barRow(_ bar: TrackingTimelineBar) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color(for: bar))
                    .frame(width: 11, height: 11)
                Text(bar.displayName ?? "Conto")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                barTrailingLabel(bar)
            }
            Capsule()
                .fill(Palette.neutralFill)
                .frame(height: 14)
                .overlay(alignment: .leading) {
                    if let fraction = bar.startFraction {
                        GeometryReader { geo in
                            Capsule()
                                .fill(color(for: bar).opacity(0.9))
                                .frame(width: max(geo.size.width * (1 - fraction), 6))
                                .offset(x: geo.size.width * fraction)
                        }
                    }
                }
                .overlay {
                    if bar.isConstraining {
                        Capsule().strokeBorder(Palette.accent.opacity(0.5), lineWidth: 2)
                    }
                }
        }
    }

    @ViewBuilder
    private func barTrailingLabel(_ bar: TrackingTimelineBar) -> some View {
        if bar.isConstraining {
            Text("determina la data")
                .font(Typography.eyebrow)
                .foregroundStyle(Palette.accent)
        } else if let earliest = bar.earliest {
            Text("da \(monthYear(earliest))")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        } else {
            Text("nessun movimento")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkQuaternary)
                .lineLimit(1)
        }
    }

    private func color(for bar: TrackingTimelineBar) -> Color {
        Palette.color(model.accountColors[bar.accountID] ?? .slate)
    }

    /// "mar 2026" — a short month/year for the axis and the per-account "da …"
    /// labels. Locale-driven, same half-measure `DashboardView` uses.
    private func monthYear(_ date: CalendarDate) -> String {
        guard let d = date.date() else { return date.wireValue }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter.string(from: d)
    }
}
