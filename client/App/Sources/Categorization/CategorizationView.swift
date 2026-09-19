import SwiftUI
import TraccioCore

/// "Categorie e regole" — manages the caller's categories and
/// categorization rules, and runs `POST /rules/apply`. Reached from the
/// "Altro" tab (ADR 0009; moved there from Impostazioni by
/// `docs/decisions/0033-more-tab-and-settings-corner.md`).
///
/// No mockup covers this screen (`docs/design/canvas/` has no Categorie/
/// Regole artboard), so it is built from existing tokens/components — same
/// posture as `TransfersView`. Pushed, so it has no `NavigationStack` of its
/// own.
struct CategorizationView: View {
    @State private var model: CategorizationViewModel
    @State private var isPresentingRuleSheet = false
    @State private var ruleSheetMode: RuleEditorSheet.Mode = .create
    @State private var isPresentingCategorySheet = false
    @State private var categorySheetMode: CategoryEditorSheet.Mode = .create(parentID: nil)
    @State private var ruleToDelete: RuleResponse?
    @State private var categoryToDelete: CategoryResponse?
    /// Set when the user tried to delete a category that still has children —
    /// known from already-loaded data, so this never needs a round trip: see
    /// `categoriesCard`'s doc comment.
    @State private var categoryDeletionBlocked: CategoryResponse?
    /// Same pre-check, for a drag-drop that would move a category with
    /// children under another root (`409 category_has_children`).
    @State private var categoryMoveBlocked: CategoryResponse?
    @State private var isConfirmingApply = false
    @State private var searchText = ""
    /// Whether a drag is currently hovering the "rendi principale" drop zone
    /// — the only place this screen puts an accent stroke, since it marks
    /// exactly what's targeted right now (`docs/engineering.md`'s dosage rule).
    @State private var isTargetingRootZone = false
    /// The root row currently under a drag, for the same accent-on-target
    /// treatment as `isTargetingRootZone`.
    @State private var targetedRootID: UUID?

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onSuggestionsChanged:
    ///     Called after a write that can change a transaction's effective
    ///     category, so the caller can invalidate other screens.
    init(
        client: any APIClientProtocol = APIClient.current,
        onSuggestionsChanged: @escaping () -> Void = {}
    ) {
        _model = State(
            wrappedValue: CategorizationViewModel(client: client, onSuggestionsChanged: onSuggestionsChanged)
        )
    }

    var body: some View {
        ScrollView {
            content
                .padding(Spacing.gutter)
        }
        .screenChrome("Categorie e regole")
        .animation(.easeInOut(duration: 0.2), value: model.state.tag)
        .refreshable { await model.load() }
        .task { await model.load() }
        .searchable(text: $searchText, prompt: "Cerca categorie e regole")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isPresentingRuleSheet) {
            if case .loaded(let data) = model.state {
                RuleEditorSheet(
                    mode: ruleSheetMode,
                    categories: data.categories,
                    isSaving: model.isUpdating,
                    failureMessage: model.actionFailure != nil ? failureMessage : nil,
                    onSubmit: { categoryID, matchKind, pattern in
                        Task {
                            switch ruleSheetMode {
                            case .create:
                                await model.createRule(
                                    categoryID: categoryID, matchKind: matchKind, pattern: pattern
                                )
                            case .edit(let rule):
                                await model.updateRule(
                                    rule, categoryID: categoryID, matchKind: matchKind, pattern: pattern
                                )
                            }
                            if model.actionFailure == nil {
                                isPresentingRuleSheet = false
                            }
                        }
                    },
                    onCancel: { isPresentingRuleSheet = false }
                )
            }
        }
        .sheet(isPresented: $isPresentingCategorySheet) {
            CategoryEditorSheet(
                mode: categorySheetMode,
                isSaving: model.isUpdating,
                failureMessage: model.actionFailure != nil ? failureMessage : nil,
                onSave: { name, color, icon in
                    Task {
                        switch categorySheetMode {
                        case .create(let parentID):
                            await model.createCategory(
                                name: name, parentID: parentID, color: color, icon: icon
                            )
                        case .edit(let category):
                            await model.updateCategory(category, name: name, color: color, icon: icon)
                        }
                        if model.actionFailure == nil {
                            isPresentingCategorySheet = false
                        }
                    }
                },
                onCancel: { isPresentingCategorySheet = false }
            )
        }
        .alert(
            "Elimina prima le sotto-categorie",
            isPresented: Binding(
                get: { categoryDeletionBlocked != nil }, set: { if !$0 { categoryDeletionBlocked = nil } }
            ),
            presenting: categoryDeletionBlocked
        ) { _ in
            Button("Ho capito", role: .cancel) {}
        } message: { category in
            Text(
                "«\(category.name)» ha delle sotto-categorie: elimina prima quelle, poi potrai eliminare «\(category.name)»."
            )
        }
        .alert(
            "Impossibile spostare la categoria",
            isPresented: Binding(
                get: { categoryMoveBlocked != nil }, set: { if !$0 { categoryMoveBlocked = nil } }
            ),
            presenting: categoryMoveBlocked
        ) { _ in
            Button("Ho capito", role: .cancel) {}
        } message: { category in
            Text(
                "«\(category.name)» ha delle sotto-categorie: non può diventare a sua volta una sotto-categoria."
            )
        }
    }

    /// Replaces the two accent `PillButton`s that used to sit inside the
    /// Regole/Categorie cards ("Nuova regola" / "Nuova categoria") — the
    /// only remaining in-card accent action is "Applica regole", so this
    /// screen shows exactly one primary CTA at a time
    /// (`docs/engineering.md`'s dosage rule), whichever state it's in.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    categorySheetMode = .create(parentID: nil)
                    isPresentingCategorySheet = true
                } label: {
                    Label("Nuova categoria", systemImage: "tag")
                }
                Button {
                    ruleSheetMode = .create
                    isPresentingRuleSheet = true
                } label: {
                    Label("Nuova regola", systemImage: "text.badge.plus")
                }
                .disabled(categoriesAreEmpty)
            } label: {
                Label("Aggiungi", systemImage: "plus")
            }
        }
    }

    private var categoriesAreEmpty: Bool {
        guard case .loaded(let data) = model.state else { return true }
        return data.categories.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        case .loaded(let data):
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                if model.actionFailure != nil {
                    Banner(message: failureMessage)
                }
                rulesCard(data)
                categoriesCard(data)
            }
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare categorie e regole",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.load() } }
            )
        }
    }

    private var failureMessage: String {
        switch model.actionFailure {
        case .categoryInUse:
            "La categoria è confermata su almeno un movimento e non può essere eliminata. Rimuovi prima la conferma dai movimenti, oppure rinominala."
        case .nameTaken:
            "Esiste già una categoria con questo nome."
        case .duplicateRule:
            "Esiste già una regola con lo stesso predicato e lo stesso testo."
        case .invalidPattern:
            "Il testo della regola non è valido."
        case .categoryHasChildren:
            "Questa categoria ha delle sotto-categorie: non può diventare a sua volta una sotto-categoria."
        case .invalidMove:
            "Non è possibile spostare la categoria qui."
        case .generic, .none:
            "Non è stato possibile completare l'operazione. Riprova."
        }
    }

    // MARK: Regole

    private func rulesCard(_ data: CategorizationViewModel.Content) -> some View {
        let categoryNames = Dictionary(uniqueKeysWithValues: data.categories.map { ($0.id, $0.name) })
        let visibleRules = TraccioCore.filterRules(
            data.rules, matching: searchText, categoryNames: categoryNames
        )
        return Card {
            EyebrowLabel(text: "Regole · in ordine di valutazione")
            Text("A parità di corrispondenza vince il pattern più lungo.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            if data.rules.isEmpty {
                Text(
                    data.categories.isEmpty
                        ? "Crea prima una categoria per poter creare una regola."
                        : "Non hai ancora nessuna regola."
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            } else if visibleRules.isEmpty {
                Text("Nessun risultato per «\(searchText)».")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleRules) { rule in
                        RuleRow(
                            rule: rule,
                            categoryName: categoryNames[rule.categoryID],
                            isDeleting: model.isUpdating,
                            onEdit: {
                                ruleSheetMode = .edit(rule)
                                isPresentingRuleSheet = true
                            },
                            onDelete: { ruleToDelete = rule }
                        )
                        if rule.id != visibleRules.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
            if !data.rules.isEmpty {
                Divider().overlay(Palette.separator)
                applyFooter(data)
            }
        }
        .confirmationDialog(
            "Eliminare la regola?",
            isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
            titleVisibility: .visible,
            presenting: ruleToDelete
        ) { rule in
            Button("Elimina", role: .destructive) {
                Task { await model.deleteRule(id: rule.id) }
            }
            Button("Chiudi", role: .cancel) {}
        } message: { rule in
            Text("La regola su \"\(rule.pattern)\" verrà eliminata.")
        }
    }

    /// "Applica regole" — a large, undoable write over every transaction
    /// (ADR 0005: a full recompute, not incremental), so it asks first
    /// rather than acting on a single tap, same posture as
    /// `AdvanceSections`'s destructive actions.
    private func applyFooter(_ data: CategorizationViewModel.Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tightGap) {
            if let result = model.lastApplyResult {
                Text(
                    "\(result.rulesApplied) regole applicate · \(result.matched) movimenti su \(result.matched + result.cleared) hanno un suggerimento"
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
            }
            PillButton(
                title: "Applica regole", isLoading: model.isUpdating,
                action: { isConfirmingApply = true }
            )
        }
        .confirmationDialog(
            "Applicare tutte le regole?", isPresented: $isConfirmingApply, titleVisibility: .visible
        ) {
            Button("Applica") { Task { await model.applyRules() } }
            Button("Chiudi", role: .cancel) {}
        } message: {
            Text(
                "Ricalcola i suggerimenti su tutti i movimenti in base alle regole attuali. Le categorie confermate a mano non vengono toccate."
            )
        }
    }

    // MARK: Categorie

    /// A category is a strict two-level tree (ADR 0018):
    /// `TraccioCore.categoryTree(_:)` regroups the flat, backend-ordered list
    /// into roots with their own children, purely for rendering. Deleting a
    /// root with children is refused server-side (`409
    /// category_has_children`), but that refusal is already knowable from
    /// `data.categories` itself — a root has children iff some other loaded
    /// category names it as `parentID` — so the trash action checks that
    /// first and skips the round trip entirely when it would fail.
    private func categoriesCard(_ data: CategorizationViewModel.Content) -> some View {
        Card {
            EyebrowLabel(text: "Categorie")
            if data.categories.isEmpty {
                emptyCategoriesState
            } else {
                let tree = TraccioCore.categoryTree(data.categories)
                let visibleTree = TraccioCore.filterCategoryTree(tree, matching: searchText)
                if visibleTree.isEmpty {
                    Text("Nessun risultato per «\(searchText)».")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleTree) { node in
                            categoryRow(node.category, indented: false, hasChildren: !node.children.isEmpty)
                            ForEach(node.children) { child in
                                categoryRow(child, indented: true, hasChildren: false)
                            }
                            if node.id != visibleTree.last?.id {
                                Divider().overlay(Palette.separator)
                            }
                        }
                    }
                }
                rootDropZone(data)
            }
        }
        .confirmationDialog(
            "Eliminare la categoria?",
            isPresented: Binding(get: { categoryToDelete != nil }, set: { if !$0 { categoryToDelete = nil } }),
            titleVisibility: .visible,
            presenting: categoryToDelete
        ) { category in
            Button("Elimina", role: .destructive) {
                Task { await model.deleteCategory(id: category.id) }
            }
            Button("Chiudi", role: .cancel) {}
        } message: { category in
            Text("«\(category.name)» verrà eliminata. Le regole che la usano continueranno a esistere.")
        }
    }

    /// A fresh database has no categories yet — rule creation would
    /// otherwise dead-end. Same fix as `TransactionDetailView`'s picker.
    private var emptyCategoriesState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Non hai ancora nessuna categoria.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            PillButton(
                title: "Crea categorie predefinite",
                isLoading: model.isUpdating,
                action: { Task { await model.seedDefaultCategories() } }
            )
        }
    }

    private func categoryRow(
        _ category: CategoryResponse, indented: Bool, hasChildren: Bool
    ) -> some View {
        HStack(spacing: 10) {
            IconTile(
                systemImage: (category.icon ?? .other).systemImageName,
                color: category.color,
                diameter: 28
            )
            Text(category.name)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            if !indented {
                IconButton(
                    systemImage: "plus",
                    accessibilityLabel: "Nuova sotto-categoria di \(category.name)",
                    action: {
                        categorySheetMode = .create(parentID: category.id)
                        isPresentingCategorySheet = true
                    }
                )
            }
            IconButton(
                systemImage: "pencil",
                accessibilityLabel: "Modifica \(category.name)",
                action: {
                    categorySheetMode = .edit(category)
                    isPresentingCategorySheet = true
                }
            )
            IconButton(
                systemImage: "trash",
                accessibilityLabel: "Elimina \(category.name)",
                isLoading: model.isUpdating,
                action: {
                    if hasChildren {
                        categoryDeletionBlocked = category
                    } else {
                        categoryToDelete = category
                    }
                }
            )
        }
        .padding(.vertical, 6)
        .padding(.leading, indented ? 24 : 0)
        .contentShape(Rectangle())
        .draggable(category.id.uuidString) { dragPreview(category) }
        .applyingIf(!indented) { row in
            row
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: targetedRootID == category.id ? 2 : 0)
                )
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items, ontoRoot: category)
                } isTargeted: { isTargeted in
                    targetedRootID = isTargeted ? category.id : nil
                }
        }
    }

    private func dragPreview(_ category: CategoryResponse) -> some View {
        HStack(spacing: Spacing.tightGap) {
            IconTile(
                systemImage: (category.icon ?? .other).systemImageName, color: category.color,
                diameter: 24
            )
            Text(category.name).font(Typography.body.weight(.semibold))
        }
        .padding(Spacing.tightGap)
    }

    /// A category with children can't itself become a child (`409
    /// category_has_children`) — pre-checked here the same way the trash
    /// action pre-checks it, from already-loaded data. Dropping onto a
    /// category's own current parent, or onto itself, is a silent no-op —
    /// nothing actually changed.
    private func handleDrop(_ items: [String], ontoRoot target: CategoryResponse) -> Bool {
        guard case .loaded(let data) = model.state,
            let raw = items.first, let draggedID = UUID(uuidString: raw),
            let dragged = data.categories.first(where: { $0.id == draggedID }),
            dragged.id != target.id,
            dragged.parentID != target.id
        else { return false }
        if data.categories.contains(where: { $0.parentID == dragged.id }) {
            categoryMoveBlocked = dragged
            return false
        }
        Task { await model.moveCategory(id: dragged.id, parentID: target.id) }
        return true
    }

    /// Drop target for "make this a root" — reuses the dashed-border idiom
    /// Conti's own add-cards retired (this UI batch's Area 1), in the one
    /// place a provisional, dashed target is exactly right. Shown only when
    /// there's a child category that could actually be dropped here.
    @ViewBuilder
    private func rootDropZone(_ data: CategorizationViewModel.Content) -> some View {
        if data.categories.contains(where: { $0.parentID != nil }) {
            HStack(spacing: Spacing.tightGap) {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 13, weight: .bold))
                Text("Trascina una sotto-categoria qui per renderla principale")
                    .font(Typography.caption.weight(.bold))
            }
            .foregroundStyle(Palette.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: isTargetingRootZone ? 2 : 0)
            )
            .dropDestination(for: String.self) { items, _ in
                handleDropToRoot(items)
            } isTargeted: { isTargeted in
                isTargetingRootZone = isTargeted
            }
        }
    }

    private func handleDropToRoot(_ items: [String]) -> Bool {
        guard case .loaded(let data) = model.state,
            let raw = items.first, let draggedID = UUID(uuidString: raw),
            let dragged = data.categories.first(where: { $0.id == draggedID }),
            dragged.parentID != nil
        else { return false }
        Task { await model.moveCategory(id: dragged.id, parentID: nil) }
        return true
    }
}

extension View {
    /// Applies `transform` only when `condition` holds — used where a
    /// conditional modifier chain (here, "only root rows are drop targets")
    /// would otherwise force an `if`/`else` with two differently-typed
    /// branches at every call site.
    @ViewBuilder
    fileprivate func applyingIf<Transformed: View>(
        _ condition: Bool, _ transform: (Self) -> Transformed
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
