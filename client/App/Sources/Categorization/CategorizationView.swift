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
    @State private var isPresentingCreateRuleSheet = false
    @State private var isPresentingCategorySheet = false
    @State private var categorySheetMode: CategoryEditorSheet.Mode = .create(parentID: nil)
    @State private var ruleToDelete: RuleResponse?
    @State private var categoryToDelete: CategoryResponse?
    /// Set when the user tried to delete a category that still has children —
    /// known from already-loaded data, so this never needs a round trip: see
    /// `categoriesCard`'s doc comment.
    @State private var categoryDeletionBlocked: CategoryResponse?
    @State private var isConfirmingApply = false

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
        .animation(.easeInOut(duration: 0.2), value: stateTag)
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $isPresentingCreateRuleSheet) {
            if case .loaded(let data) = model.state {
                CreateRuleSheet(
                    categories: data.categories,
                    isCreating: model.isUpdating,
                    failureMessage: model.actionFailure != nil ? failureMessage : nil,
                    onCreate: { categoryID, matchKind, pattern in
                        Task {
                            await model.createRule(categoryID: categoryID, matchKind: matchKind, pattern: pattern)
                            if model.actionFailure == nil {
                                isPresentingCreateRuleSheet = false
                            }
                        }
                    },
                    onCancel: { isPresentingCreateRuleSheet = false }
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
                            await model.renameCategory(id: category.id, name: name)
                            if model.actionFailure == nil {
                                await model.setCategoryAppearance(
                                    id: category.id, color: color, icon: icon
                                )
                            }
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
    }

    /// A cheap discriminator for `.animation(_:value:)` — see
    /// `TransactionsView.stateTag`'s doc comment for why not `Equatable`.
    private var stateTag: String {
        switch model.state {
        case .idle, .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
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
        case .generic, .none:
            "Non è stato possibile completare l'operazione. Riprova."
        }
    }

    // MARK: Regole

    private func rulesCard(_ data: CategorizationViewModel.Content) -> some View {
        Card {
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
            } else {
                VStack(spacing: 0) {
                    ForEach(data.rules) { rule in
                        RuleRow(
                            rule: rule,
                            categoryName: categoryName(for: rule.categoryID, in: data),
                            isDeleting: model.isUpdating,
                            onDelete: { ruleToDelete = rule }
                        )
                        if rule.id != data.rules.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
            Divider().overlay(Palette.separator)
            PillButton(title: "Nuova regola", action: { isPresentingCreateRuleSheet = true })
                .disabled(data.categories.isEmpty)
            applyFooter(data)
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
        VStack(alignment: .leading, spacing: 8) {
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
            .disabled(data.rules.isEmpty)
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

    private func categoryName(for id: UUID, in data: CategorizationViewModel.Content) -> String? {
        data.categories.first { $0.id == id }?.name
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
                VStack(spacing: 0) {
                    ForEach(tree) { node in
                        categoryRow(node.category, indented: false, hasChildren: !node.children.isEmpty)
                        ForEach(node.children) { child in
                            categoryRow(child, indented: true, hasChildren: false)
                        }
                        if node.id != tree.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
            Divider().overlay(Palette.separator)
            PillButton(
                title: "Nuova categoria",
                action: {
                    categorySheetMode = .create(parentID: nil)
                    isPresentingCategorySheet = true
                }
            )
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
    }
}
