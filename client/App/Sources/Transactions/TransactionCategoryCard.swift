import SwiftUI
import TraccioCore

/// `TransactionDetailView`'s category card: the two-level picker (ADR 0018),
/// the "seed defaults" affordance for a fresh database, and — once a category
/// is confirmed — "Rimuovi categoria" and "Categorizza sempre così".
struct TransactionCategoryCard: View {
    let categories: [CategoryResponse]
    let transaction: TransactionResponse
    let isUpdating: Bool
    let onSeedDefaults: () -> Void
    let onConfirm: (UUID) -> Void
    let onClear: () -> Void
    let onCreateRule: () -> Void

    var body: some View {
        Card {
            EyebrowLabel(text: "Categoria")
            if categories.isEmpty {
                emptyState
            } else {
                categoryList
                if transaction.confirmedCategoryID != nil {
                    Divider().overlay(Palette.separator)
                    clearCategoryRow
                    PillButton(title: "Categorizza sempre così", action: onCreateRule)
                }
            }
        }
    }

    /// A fresh database has no categories yet — the picker would dead-end
    /// without a way to seed the defaults (`POST /categories/defaults`).
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Non hai ancora nessuna categoria.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            PillButton(title: "Crea categorie predefinite", isLoading: isUpdating, action: onSeedDefaults)
        }
    }

    /// Two-level picker: each root immediately followed by its own children,
    /// indented — `TraccioCore.categoryTree(_:)` does the pure regrouping,
    /// this view only adds indentation.
    private var categoryList: some View {
        let tree = TraccioCore.categoryTree(categories)
        return VStack(spacing: 0) {
            ForEach(tree) { node in
                categoryRow(node.category, indented: false)
                if !node.children.isEmpty {
                    Divider().overlay(Palette.separatorSubtle)
                }
                ForEach(node.children) { child in
                    categoryRow(child, indented: true)
                    if child.id != node.children.last?.id {
                        Divider().overlay(Palette.separatorSubtle)
                    }
                }
                if node.id != tree.last?.id {
                    Divider().overlay(Palette.separator)
                }
            }
        }
    }

    private func categoryRow(_ category: CategoryResponse, indented: Bool) -> some View {
        let isConfirmed = category.id == transaction.confirmedCategoryID
        // A suggestion renders as a lightweight tag, never the checkmark
        // reserved for an explicit confirmation — tapping still confirms it,
        // same as any other row.
        let isSuggestedOnly = !isConfirmed && category.id == transaction.suggestedCategoryID
        return Button {
            onConfirm(category.id)
        } label: {
            HStack(spacing: 10) {
                IconTile(
                    systemImage: (category.icon ?? .other).systemImageName,
                    color: category.color,
                    diameter: 28
                )
                Text(category.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                if isSuggestedOnly {
                    Badge(text: "Suggerita", style: .neutral)
                }
                Spacer()
                if isConfirmed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, indented ? 24 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .accessibilityAddTraits(isConfirmed ? [.isSelected] : [])
    }

    private var clearCategoryRow: some View {
        Button(action: onClear) {
            Text("Rimuovi categoria")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
    }
}
