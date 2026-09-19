import SwiftUI
import TraccioCore

/// One rule in `CategorizationView`'s Regole card: its predicate, its
/// pattern, the category it resolves to, and an edit/delete overflow menu.
///
/// Pure presentation — no view model. The resolved category name is passed
/// in rather than looked up here, since the row has no client of its own.
/// The trailing control is a `Menu`, not a plain delete `IconButton`, since
/// it now offers two actions and a `Button` can't nest another `Button` —
/// same constraint Conti's collapsed single-account card works around by
/// keeping its sync control as a sibling, not a child, of the row's `Button`.
struct RuleRow: View {
    let rule: RuleResponse
    /// The rule's target category name, resolved by the caller against the
    /// loaded category list; `nil` only if the two lists are momentarily out
    /// of sync (a stale category id) — degrades to "categoria sconosciuta"
    /// rather than hiding the row.
    let categoryName: String?
    let isDeleting: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.itemGap) {
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
            Spacer(minLength: 8)
            Menu {
                Button(action: onEdit) {
                    Label("Modifica", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Elimina", systemImage: "trash")
                }
            } label: {
                IconButtonLabel(systemImage: "ellipsis", isLoading: isDeleting)
            }
            .disabled(isDeleting)
            .accessibilityLabel("Azioni regola")
        }
        .padding(.vertical, 6)
        .rowScrollTransition()
    }

    private var matchKindLabel: String {
        switch rule.matchKind {
        case .contains: "Contiene"
        case .startsWith: "Inizia con"
        case .equals: "È esattamente"
        }
    }
}
