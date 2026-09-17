import SwiftUI

/// One removable token per active Movimenti filter dimension, or nothing at
/// all when no filter is set — so the list starts right under the search
/// field in the common case. Setting a filter is the toolbar's filter button
/// (which opens `TransactionFiltersSheet`); this row only *shows and clears*
/// what is active. Inside a horizontal `ScrollView` so a long label
/// ("Abbonamenti e servizi") scrolls into view instead of squeezing its
/// neighbours or wrapping (`docs/design/tokens.md`: never wrap).
struct ActiveFilterTokensRow: View {
    /// One active dimension's chip: its label and what clearing it does.
    struct Token {
        let title: String
        let onClear: () -> Void
    }

    let accountToken: Token?
    let categoryToken: Token?
    let periodToken: Token?

    var body: some View {
        if accountToken != nil || categoryToken != nil || periodToken != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let accountToken { chip(accountToken) }
                    if let categoryToken { chip(categoryToken) }
                    if let periodToken { chip(periodToken) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }

    private func chip(_ token: Token) -> some View {
        Button(action: token.onClear) {
            FilterChip(title: token.title, isActive: true)
        }
    }
}
