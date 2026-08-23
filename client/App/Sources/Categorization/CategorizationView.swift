import SwiftUI
import TraccioCore

/// "Categorie e regole" — manages the caller's categories and
/// categorization rules. Running `POST /rules/apply` lands in a later
/// slice. Reached from the Impostazioni tab (ADR 0009).
///
/// No mockup covers this screen (`docs/design/canvas/` has no Categorie/
/// Regole artboard), so it is built from existing tokens/components — same
/// posture as `TransfersView`. Pushed, so it has no `NavigationStack` of its
/// own.
struct CategorizationView: View {
    @State private var model: CategorizationViewModel
    @State private var isPresentingCreateRuleSheet = false
    @State private var isPresentingCategorySheet = false
    /// `nil` means the category sheet is creating; set means it is renaming.
    @State private var editingCategory: CategoryResponse?
    @State private var ruleToDelete: RuleResponse?
    @State private var categoryToDelete: CategoryResponse?

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
        client: any APIClientProtocol = APIClient.devDefault,
        onSuggestionsChanged: @escaping () -> Void = {}
    ) {
        _model = State(
            wrappedValue: CategorizationViewModel(client: client, onSuggestionsChanged: onSuggestionsChanged)
        )
    }

    var body: some View {
        ScrollView {
            content
                .padding(20)
        }
        .background(Palette.background)
        .navigationTitle("Categorie e regole")
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
                mode: editingCategory.map { .rename($0) } ?? .create,
                isSaving: model.isUpdating,
                failureMessage: model.actionFailure != nil ? failureMessage : nil,
                onSave: { name in
                    Task {
                        if let editingCategory {
                            await model.renameCategory(id: editingCategory.id, name: name)
                        } else {
                            await model.createCategory(name: name)
                        }
                        if model.actionFailure == nil {
                            isPresentingCategorySheet = false
                        }
                    }
                },
                onCancel: { isPresentingCategorySheet = false }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        case .loaded(let data):
            VStack(alignment: .leading, spacing: 16) {
                if model.actionFailure != nil {
                    Banner(message: failureMessage)
                }
                rulesCard(data)
                categoriesCard(data)
            }
        case .failed:
            ContentUnavailableView {
                Label("Impossibile caricare categorie e regole", systemImage: "wifi.slash")
            } description: {
                Text("Verifica che il backend sia in esecuzione, poi riprova.")
            }
            .frame(maxWidth: .infinity, minHeight: 240)
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

    /// Running `POST /rules/apply` lands in a later slice.
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

    private func categoryName(for id: UUID, in data: CategorizationViewModel.Content) -> String? {
        data.categories.first { $0.id == id }?.name
    }

    // MARK: Categorie

    private func categoriesCard(_ data: CategorizationViewModel.Content) -> some View {
        Card {
            EyebrowLabel(text: "Categorie")
            if data.categories.isEmpty {
                emptyCategoriesState
            } else {
                VStack(spacing: 0) {
                    ForEach(data.categories) { category in
                        categoryRow(category)
                        if category.id != data.categories.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
            Divider().overlay(Palette.separator)
            PillButton(
                title: "Nuova categoria",
                action: {
                    editingCategory = nil
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

    private func categoryRow(_ category: CategoryResponse) -> some View {
        HStack(spacing: 12) {
            Text(category.name)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            IconButton(
                systemImage: "pencil",
                accessibilityLabel: "Rinomina \(category.name)",
                action: {
                    editingCategory = category
                    isPresentingCategorySheet = true
                }
            )
            IconButton(
                systemImage: "trash",
                accessibilityLabel: "Elimina \(category.name)",
                isLoading: model.isUpdating,
                action: { categoryToDelete = category }
            )
        }
        .padding(.vertical, 6)
    }
}
