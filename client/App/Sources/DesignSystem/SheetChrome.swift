import SwiftUI

extension View {
    /// The chrome every sheet shares: the neutral background gradient, an
    /// inline title (a sheet is a focused task, not a place worth a large
    /// title), and the resizable-sheet presentation — `.medium`/`.large`
    /// detents with a visible drag indicator.
    ///
    /// Apply to the content inside the sheet's own `NavigationStack`, same
    /// place `.toolbar` already goes:
    ///
    /// ```swift
    /// NavigationStack {
    ///     ScrollView { ... }
    ///         .sheetChrome("Nuova regola")
    ///         .toolbar { ... }
    /// }
    /// ```
    ///
    /// Before the 2026-09-15 coherence pass
    /// (`docs/decisions/0031-visual-coherence-pass.md`) only two sheets
    /// (`SelectionSheet`, `TransactionFiltersSheet`) had detents or a drag
    /// indicator; the other fourteen were full-height with no resize
    /// affordance. `presentationDetents`/`presentationDragIndicator` are
    /// presentation traits that propagate up through any container to the
    /// sheet doing the presenting, so applying them here — rather than on
    /// the outer `NavigationStack`, as the two pre-existing call sites did
    /// — still reaches the presentation; it just keeps everything about a
    /// sheet's chrome in one call.
    func sheetChrome(_ title: String, detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        modifier(SheetChromeModifier(title: title, detents: detents))
    }
}

private struct SheetChromeModifier: ViewModifier {
    let title: String
    let detents: Set<PresentationDetent>

    func body(content: Content) -> some View {
        content
            .screenBackground()
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
    }
}
