import SwiftUI
import TraccioCore

/// The Movimenti filter sheet — one token-built bottom sheet in place of the
/// three native `Menu`s (`docs/design/canvas/TransactionsFilters.dc.html`,
/// Fase B redesign). Conto, Categoria (a real two-level tree, not the old
/// arrow-prefixed flat list), and Periodo, accumulated locally and applied
/// once on "Applica" so the list behind the sheet reloads at most once per
/// visit.
///
/// Presentation only: it renders the current selection and reports the new
/// one. `TransactionsView` turns the period preset into a date range and
/// hands the whole thing to `TransactionsViewModel.applyFilter(_:)` — the
/// filtering still happens server-side.
struct TransactionFiltersSheet: View {
    /// Accounts to choose from, already in display order.
    let accounts: [AccountResponse]
    /// Roots with their direct children (`TraccioCore.categoryTree`).
    let categoryTree: [CategoryTreeNode]
    /// Italian label for a period preset — display copy stays in the view
    /// layer (`TransactionPeriodPreset`'s own doc comment).
    let periodTitle: (TransactionPeriodPreset) -> String

    @State private var accountID: UUID?
    @State private var category: TransactionFilter.CategoryFilter
    @State private var period: TransactionPeriodPreset

    /// Called with the accumulated selection when the user taps "Applica".
    let onApply: (UUID?, TransactionFilter.CategoryFilter, TransactionPeriodPreset) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        accountID: UUID?,
        category: TransactionFilter.CategoryFilter,
        period: TransactionPeriodPreset,
        accounts: [AccountResponse],
        categoryTree: [CategoryTreeNode],
        periodTitle: @escaping (TransactionPeriodPreset) -> String,
        onApply: @escaping (UUID?, TransactionFilter.CategoryFilter, TransactionPeriodPreset) -> Void
    ) {
        _accountID = State(initialValue: accountID)
        _category = State(initialValue: category)
        _period = State(initialValue: period)
        self.accounts = accounts
        self.categoryTree = categoryTree
        self.periodTitle = periodTitle
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountSection
                    categorySection
                    periodSection
                }
                .padding(Spacing.gutter)
            }
            .background(Palette.background)
            .navigationTitle("Filtri")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Azzera") {
                        accountID = nil
                        category = .any
                        period = .all
                    }
                    .disabled(!isAnyFilterActive)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onApply(accountID, category, period)
                    dismiss()
                } label: {
                    Text("Applica")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .buttonBorderShape(.roundedRectangle(radius: Radius.row))
                .padding(Spacing.gutter)
                .glassEffect(.regular, in: Rectangle())
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isAnyFilterActive: Bool {
        accountID != nil || category != .any || period != .all
    }

    // MARK: Conto

    private var accountSection: some View {
        section("Conto") {
            optionCard {
                optionRow(title: "Tutti i conti", isSelected: accountID == nil) {
                    accountID = nil
                }
                ForEach(accounts) { account in
                    Divider().overlay(Palette.separator)
                    optionRow(
                        title: account.displayName ?? "Conto",
                        swatch: Palette.color(account.tileColor),
                        isSelected: accountID == account.id
                    ) {
                        accountID = account.id
                    }
                }
            }
        }
    }

    // MARK: Categoria

    private var categorySection: some View {
        section("Categoria") {
            optionCard {
                optionRow(title: "Tutte le categorie", isSelected: category == .any) {
                    category = .any
                }
                Divider().overlay(Palette.separator)
                optionRow(title: "Senza categoria", isSelected: category == .uncategorized) {
                    category = .uncategorized
                }
                ForEach(categoryTree) { node in
                    Divider().overlay(Palette.separator)
                    optionRow(
                        title: node.category.name,
                        swatch: Palette.color(node.category.color),
                        isSelected: category == .some(node.category.id)
                    ) {
                        category = .some(node.category.id)
                    }
                    ForEach(node.children) { child in
                        Divider().overlay(Palette.separator)
                        optionRow(
                            title: child.name,
                            swatch: Palette.color(child.color),
                            isSelected: category == .some(child.id),
                            indented: true
                        ) {
                            category = .some(child.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: Periodo

    private var periodSection: some View {
        section("Periodo") {
            // A wrapping row of pills — the one place in the client where
            // wrapping is intended (a standalone control group in a sheet,
            // not a list line — `docs/design/tokens.md`).
            FlowRow(spacing: 8) {
                ForEach(TransactionPeriodPreset.allCases, id: \.self) { preset in
                    let isSelected = period == preset
                    Button { period = preset } label: {
                        Text(periodTitle(preset))
                            .font(Typography.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Palette.accent : Palette.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                isSelected ? Palette.accent.opacity(0.12) : Palette.card,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isSelected ? Palette.accent.opacity(0.3) : Palette.separator
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EyebrowLabel(text: label)
            content()
        }
    }

    private func optionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(Palette.separatorSubtle)
            )
    }

    private func optionRow(
        title: String,
        swatch: Color? = nil,
        isSelected: Bool,
        indented: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(swatch)
                        .frame(width: 10, height: 10)
                }
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.leading, indented ? 34 : 14)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A minimal wrapping `HStack`: lays children left to right, dropping to the
/// next line when the current one is full. Used only for the period pills in
/// `TransactionFiltersSheet` — a full flow-layout dependency would be
/// overkill for one control group.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
