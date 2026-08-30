import SwiftUI
import TraccioCore

/// "Inizio tracciamento" — the screen where the user picks the day the
/// dashboard and Movimenti begin from (ADR 0024).
///
/// Months before every account has data show only the accounts connected
/// earliest, so their totals mislead. This screen shows each account's first
/// movement, suggests the earliest month all of them cover, and lets the user
/// set, change, or clear the floor. Nothing is ever deleted — clearing brings
/// every earlier movement back.
///
/// No mockup covers this; built from the same `Card` idiom as the rest of
/// Impostazioni.
struct TrackingStartView: View {
    @State private var model: TrackingStartViewModel
    @State private var pickedDate = Date()
    @State private var pickerSeeded = false

    init(model: TrackingStartViewModel = TrackingStartViewModel()) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle("Inizio tracciamento")
        .task { await model.load() }
    }

    @ViewBuilder
    private func loaded(
        current: CalendarDate?, suggestion: TrackingStartSuggestionResponse
    ) -> some View {
        Text(
            "La Panoramica e i Movimenti partono da questa data. Prima di qui i mesi hanno i dati solo di alcuni conti, quindi i totali ingannano. Cambiarla non cancella nulla."
        )
        .font(Typography.caption)
        .foregroundStyle(Palette.inkSecondary)

        Card {
            EyebrowLabel(text: "Data attuale")
            Text(
                current.map { TraccioCore.formatCalendarDate($0) }
                    ?? "Nessuna — mostro tutti i movimenti"
            )
            .font(Typography.statFigure)
            .foregroundStyle(Palette.ink)
            if model.saveFailed {
                Text("Non è stato possibile salvare. Riprova.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
            }
        }

        Card {
            EyebrowLabel(text: "Primo movimento per conto")
            ForEach(suggestion.accounts) { account in
                accountRow(account, constraining: account.id == suggestion.constrainingAccountID)
                if account.id != suggestion.accounts.last?.id {
                    Divider().overlay(Palette.separator)
                }
            }
            if suggestion.accounts.isEmpty {
                Text("Nessun conto.").font(Typography.body).foregroundStyle(Palette.inkSecondary)
            }
        }

        if let suggested = suggestion.suggestion {
            Card {
                EyebrowLabel(text: "Consigliata")
                Text(TraccioCore.formatCalendarDate(suggested))
                    .font(Typography.statFigure)
                    .foregroundStyle(Palette.ink)
                Text("Il primo mese in cui tutti i conti hanno movimenti.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                PillButton(
                    title: "Usa la data consigliata",
                    isLoading: model.isSaving,
                    action: { Task { await model.save(suggested) } }
                )
                .disabled(current == suggested)
            }
        }

        Card {
            EyebrowLabel(text: "Scegli una data")
            DatePicker(
                "Inizio tracciamento", selection: $pickedDate, displayedComponents: .date
            )
            .labelsHidden()
            .onAppear {
                guard !pickerSeeded else { return }
                pickerSeeded = true
                if let seed = (current ?? suggestion.suggestion)?.date() {
                    pickedDate = seed
                }
            }
            PillButton(
                title: "Salva",
                isLoading: model.isSaving,
                action: { Task { await model.save(CalendarDate(date: pickedDate)) } }
            )
        }

        if current != nil {
            Button {
                Task { await model.save(nil) }
            } label: {
                Text("Azzera — mostra tutti i movimenti")
                    .font(Typography.body)
                    .foregroundStyle(Palette.warning)
            }
            .buttonStyle(.plain)
            .disabled(model.isSaving)
        }
    }

    private func accountRow(_ account: AccountEarliestResponse, constraining: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName ?? "Conto")
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if constraining {
                    Text("determina la data consigliata")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.accent)
                }
            }
            Spacer()
            Text(account.earliest.map { TraccioCore.formatCalendarDate($0) } ?? "nessun movimento")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, 6)
    }
}
