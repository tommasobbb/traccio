import SwiftUI
import TraccioCore

/// One rule in `CategorizationView`'s Regole card: its predicate, its
/// pattern, and the category it resolves to. Read-only for now — deletion
/// lands in a later slice.
///
/// Pure presentation — no view model. The resolved category name is passed
/// in rather than looked up here, since the row has no client of its own.
struct RuleRow: View {
    let rule: RuleResponse
    /// The rule's target category name, resolved by the caller against the
    /// loaded category list; `nil` only if the two lists are momentarily out
    /// of sync (a stale category id) — degrades to "categoria sconosciuta"
    /// rather than hiding the row.
    let categoryName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Badge(text: matchKindLabel, style: .neutral)
                Text(rule.pattern)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
            Text(categoryName ?? "Categoria sconosciuta")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var matchKindLabel: String {
        switch rule.matchKind {
        case .contains: "Contiene"
        case .startsWith: "Inizia con"
        case .equals: "È esattamente"
        }
    }
}
