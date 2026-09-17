import SwiftUI
import TraccioCore

/// Panoramica's period strip — previous/next chevrons around the current
/// period's title, plus the month/quarter/year unit picker.
///
/// A quiet flush card, not the old accent-tint block — the period strip is
/// navigation, not a headline, and the accent no longer wants that much
/// presence at the top of the screen (2026-09-08 tone revision, Panoramica
/// recompose). Glass here was tried and reverted
/// (`docs/decisions/0032-glass-on-raised-cards.md`).
struct DashboardPeriodPicker: View {
    let period: CalendarPeriod
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onChangeUnit: (CalendarPeriod.Unit) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Periodo precedente")
                .disabled(!canGoToPrevious)

                Text(period.displayTitle)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)

                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Periodo successivo")
                .disabled(!canGoToNext)
            }
            .buttonStyle(.plain)
            // The period chevrons are navigation chrome, not a brand touch —
            // ink, not accent (2026-09-08 tone revision, second pass).
            .foregroundStyle(Palette.inkSecondary)

            Picker("Unità", selection: Binding(get: { period.unit }, set: onChangeUnit)) {
                Text("Mese").tag(CalendarPeriod.Unit.month)
                Text("Trimestre").tag(CalendarPeriod.Unit.quarter)
                Text("Anno").tag(CalendarPeriod.Unit.year)
            }
            .pickerStyle(.segmented)
            .segmentedPickerTint()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(Palette.separatorSubtle, lineWidth: 1)
        )
    }
}
