import SwiftUI
import TraccioCore

/// The category picker, presented as a sheet from a Movimenti row's leading
/// tile — the two-tap categorization path
/// (`docs/decisions/0036-movimenti-row-actions.md`): tap the tile, tap a
/// category, the sheet closes.
///
/// Was `TransactionCategoryCard`, a `Card` embedded in `TransactionDetailView`
/// — moved here unchanged in substance (the two-level picker from ADR 0018,
/// the "seed defaults" affordance, "Rimuovi categoria") but relocated so
/// categorizing no longer requires the push to the detail screen. "Categorizza
/// sempre così" still opens `CreateRuleFromTransactionSheet`, now nested
/// inside this sheet rather than a sibling of the (no-longer-present) card —
/// `isPresentingCreateRuleSheet` is a binding so `TransactionsView`, which
/// owns the write and its outcome, decides when the nested sheet closes,
/// exactly as every other sheet's dismissal is decided by whichever view
/// holds the model.
struct CategoryPickerSheet: View {
    let categories: [CategoryResponse]
    let transaction: TransactionResponse
    var isUpdating: Bool
    /// A message describing why the last confirm/clear/seed attempt failed,
    /// or `nil`.
    var failureMessage: String?
    let onSeedDefaults: () -> Void
    let onConfirm: (UUID) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    /// Presents `CreateRuleFromTransactionSheet`. A binding, not local
    /// `@State`: `TransactionsView` awaits the create-rule call and decides
    /// success here, same as it decides this sheet's own dismissal via
    /// `onConfirm`/`onClear`.
    @Binding var isPresentingCreateRuleSheet: Bool
    /// `CreateRuleFromTransactionSheet`'s own failure copy — separate from
    /// `failureMessage` so a duplicate-rule error reads specifically inside
    /// the sheet that caused it.
    var createRuleFailureMessage: String?
    let onCreateRule: (RuleMatchKind, String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    if categories.isEmpty {
                        emptyState
                    } else {
                        categoryList
                        if transaction.confirmedCategoryID != nil {
                            Divider().overlay(Palette.separator)
                            clearCategoryRow
                            PillButton(
                                title: "Categorizza sempre così",
                                action: { isPresentingCreateRuleSheet = true }
                            )
                        }
                    }
                }
                .padding(Spacing.gutter)
            }
            .sheetChrome("Categoria")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
            }
        }
        .sheet(isPresented: $isPresentingCreateRuleSheet) {
            CreateRuleFromTransactionSheet(
                categoryName: categoryName ?? "",
                initialPattern: transaction.displayDescription ?? transaction.description,
                isCreating: isUpdating,
                failureMessage: createRuleFailureMessage,
                onCreate: onCreateRule,
                onCancel: { isPresentingCreateRuleSheet = false }
            )
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
        return Card(contentPadding: 0) {
            VStack(spacing: 0) {
                ForEach(tree) { node in
                    categoryRow(node.category, indented: false)
                    if !node.children.isEmpty {
                        Divider().overlay(Palette.separatorSubtle).padding(.leading, 16)
                    }
                    ForEach(node.children) { child in
                        categoryRow(child, indented: true)
                        if child.id != node.children.last?.id {
                            Divider().overlay(Palette.separatorSubtle).padding(.leading, 16)
                        }
                    }
                    if node.id != tree.last?.id {
                        Divider().overlay(Palette.separator).padding(.leading, 16)
                    }
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

    /// This transaction's confirmed category's name — the nested rule
    /// sheet's eyebrow ("Assegna \"X\" quando…").
    private var categoryName: String? {
        guard let id = transaction.confirmedCategoryID else { return nil }
        return categories.first { $0.id == id }?.name
    }
}
