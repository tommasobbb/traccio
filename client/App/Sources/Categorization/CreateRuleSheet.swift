import SwiftUI
import TraccioCore

/// "Nuova regola" — the form presented from `CategorizationView` to create a
/// categorization rule.
///
/// No mockup covers this screen (`docs/design/canvas/` has no Categorie/
/// Regole artboard), so it is built from existing tokens/components — same
/// posture as `CreateAdvanceSheet`. Presentational only: the pattern is
/// trimmed here to gate the submit button, but never checked for length or
/// duplication — the backend's `422`/`409` are the real checks
/// (`.claude/rules/swift.md`: the backend owns every derived value; the same
/// reasoning extends to validation the backend already performs).
struct CreateRuleSheet: View {
    let categories: [CategoryResponse]
    var isCreating: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the chosen category, predicate, and trimmed pattern once
    /// the user submits a valid form.
    let onCreate: (UUID, RuleMatchKind, String) -> Void
    let onCancel: () -> Void

    @State private var matchKind: RuleMatchKind = .contains
    @State private var patternText = ""
    @State private var selectedCategoryID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    patternCard
                    categoryCard
                }
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Nuova regola")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea", action: submit)
                        .disabled(isCreating || trimmedPattern.isEmpty || selectedCategoryID == nil)
                }
            }
        }
        .onAppear {
            if selectedCategoryID == nil {
                selectedCategoryID = categories.first?.id
            }
        }
    }

    // MARK: Pattern

    private var patternCard: some View {
        Card {
            EyebrowLabel(text: "Corrisponde quando la descrizione")
            Picker("Predicato", selection: $matchKind) {
                Text("Contiene").tag(RuleMatchKind.contains)
                Text("Inizia con").tag(RuleMatchKind.startsWith)
                Text("È esattamente").tag(RuleMatchKind.equals)
            }
            .pickerStyle(.segmented)
            TextField("Es. TEST MERCHANT 01", text: $patternText)
                .font(Typography.body)
                .autocorrectionDisabled()
        }
    }

    // MARK: Category

    private var categoryCard: some View {
        Card {
            EyebrowLabel(text: "Assegna la categoria")
            if categories.isEmpty {
                Text("Crea prima una categoria.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(categories) { category in
                        categoryRow(category)
                        if category.id != categories.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: CategoryResponse) -> some View {
        let isSelected = category.id == selectedCategoryID
        return Button {
            selectedCategoryID = category.id
        } label: {
            HStack {
                Text(category.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Submit

    private var trimmedPattern: String {
        patternText.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        guard !trimmedPattern.isEmpty, let selectedCategoryID else { return }
        onCreate(selectedCategoryID, matchKind, trimmedPattern)
    }
}
