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
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    patternCard
                    categoryCard
                }
                .padding(Spacing.gutter)
            }
            .sheetChrome("Nuova regola")
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
            .segmentedPickerTint()
            TextField("Es. TEST MERCHANT 01", text: $patternText)
                .font(Typography.body)
                .autocorrectionDisabled()
        }
    }

    // MARK: Category

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.tightGap) {
            EyebrowLabel(text: "Assegna la categoria")
            if categories.isEmpty {
                Text("Crea prima una categoria.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                OptionListCard {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        if index > 0 {
                            Divider().overlay(Palette.separator)
                        }
                        OptionRow(
                            title: category.name,
                            isSelected: category.id == selectedCategoryID,
                            action: { selectedCategoryID = category.id }
                        )
                    }
                }
            }
        }
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
