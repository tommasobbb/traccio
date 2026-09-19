import SwiftUI
import TraccioCore

/// "Nuova regola" / "Modifica regola" — one sheet for both, since they differ
/// only in title, prefill, and what write the caller triggers on submit;
/// mirrors `CategoryEditorSheet.Mode`'s shape for the same reason.
///
/// No mockup covers this screen (`docs/design/canvas/` has no Categorie/
/// Regole artboard), so it is built from existing tokens/components — same
/// posture as `CreateAdvanceSheet`. Presentational only: the pattern is
/// trimmed here to gate the submit button, but never checked for length or
/// duplication — the backend's `422`/`409` are the real checks
/// (`docs/engineering.md`: the backend owns every derived value; the same
/// reasoning extends to validation the backend already performs).
struct RuleEditorSheet: View {
    /// Which write this sheet drives. Modeled as an enum rather than an
    /// optional `RuleResponse` plus a boolean flag, so "editing nothing" is
    /// unrepresentable (`docs/engineering.md`) — same rationale as
    /// `CategoryEditorSheet.Mode`.
    enum Mode {
        case create
        case edit(RuleResponse)
    }

    let mode: Mode
    let categories: [CategoryResponse]
    var isSaving: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the chosen category, predicate, and trimmed pattern once
    /// the user submits a valid form — a create or an update, decided by the
    /// caller from `mode`.
    let onSubmit: (UUID, RuleMatchKind, String) -> Void
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
            .sheetChrome(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: submit)
                        .disabled(isSaving || trimmedPattern.isEmpty || selectedCategoryID == nil)
                }
            }
        }
        .onAppear {
            if case .edit(let rule) = mode, patternText.isEmpty {
                matchKind = rule.matchKind
                patternText = rule.pattern
                selectedCategoryID = rule.categoryID
            } else if selectedCategoryID == nil {
                selectedCategoryID = categories.first?.id
            }
        }
    }

    private var title: String {
        switch mode {
        case .create: "Nuova regola"
        case .edit: "Modifica regola"
        }
    }

    private var confirmTitle: String {
        switch mode {
        case .create: "Crea"
        case .edit: "Salva"
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

    /// Indented, icon-and-colour tree — the same shape
    /// `TransactionFiltersSheet.categorySection` already renders, so a rule's
    /// category picker doesn't stay the odd one out with a flat,
    /// icon-less list.
    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.tightGap) {
            EyebrowLabel(text: "Assegna la categoria")
            if categories.isEmpty {
                Text("Crea prima una categoria.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                let tree = TraccioCore.categoryTree(categories)
                OptionListCard {
                    ForEach(Array(tree.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Divider().overlay(Palette.separator)
                        }
                        OptionRow(
                            title: node.category.name,
                            icon: (node.category.tileIcon.systemImageName, node.category.color),
                            isSelected: node.category.id == selectedCategoryID,
                            action: { selectedCategoryID = node.category.id }
                        )
                        ForEach(node.children) { child in
                            Divider().overlay(Palette.separator)
                            OptionRow(
                                title: child.name,
                                icon: (child.tileIcon.systemImageName, child.color),
                                isSelected: child.id == selectedCategoryID,
                                indented: true,
                                action: { selectedCategoryID = child.id }
                            )
                        }
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
        onSubmit(selectedCategoryID, matchKind, trimmedPattern)
    }
}
