import SwiftUI

extension View {
    /// A segmented `Picker` tinted with the brand accent — the selected
    /// segment is the one place a segmented control is allowed to carry the
    /// accent (it is what you have currently touched/selected, same dose as
    /// an active `FilterChip`; `docs/design/tokens.md`'s "Accent dosage").
    /// Before the 2026-09-15 coherence pass only `DashboardView`'s period
    /// unit picker applied this tint; the other six segmented pickers in the
    /// app (predicate, transaction type, import format) rendered in the
    /// untinted system default. Apply directly after `.pickerStyle(.segmented)`.
    func segmentedPickerTint() -> some View {
        tint(Palette.accent)
    }
}
