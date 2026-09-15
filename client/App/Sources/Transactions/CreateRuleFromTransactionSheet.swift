import SwiftUI
import TraccioCore

/// "Categorizza sempre così" — the sheet `TransactionDetailView` presents to
/// turn this transaction's confirmed category into a standing rule.
///
/// Unlike `CreateRuleSheet` (Categorizzazione), the category is fixed — this
/// transaction's already-confirmed one — so there is no picker, only the
/// predicate and the pattern. `contains` is preselected and the pattern
/// starts precompiled from `displayDescription ?? description`, but stays
/// editable: the raw bank text often carries a date or reference number the
/// user needs to trim down to the merchant fragment before it becomes a
/// standing rule.
struct CreateRuleFromTransactionSheet: View {
    let categoryName: String
    var isCreating: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the chosen predicate and trimmed pattern once the user
    /// submits a valid form.
    let onCreate: (RuleMatchKind, String) -> Void
    let onCancel: () -> Void

    @State private var matchKind: RuleMatchKind = .contains
    @State private var patternText: String

    /// Create the sheet.
    ///
    /// Parameters
    /// ----------
    /// categoryName:
    ///     The category this rule will assign — this transaction's confirmed
    ///     one, named in the eyebrow so the sheet reads as "assign X when...".
    /// initialPattern:
    ///     The pattern the text field starts with, precompiled from the
    ///     transaction's own description. Editable from there.
    /// isCreating:
    ///     Whether a create/apply call is in flight, to disable the form.
    /// failureMessage:
    ///     A message describing why the last attempt failed, or `nil`.
    /// onCreate:
    ///     Called with the chosen predicate and trimmed pattern on submit.
    /// onCancel:
    ///     Called when the user dismisses without submitting.
    init(
        categoryName: String,
        initialPattern: String,
        isCreating: Bool,
        failureMessage: String?,
        onCreate: @escaping (RuleMatchKind, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.categoryName = categoryName
        self.isCreating = isCreating
        self.failureMessage = failureMessage
        self.onCreate = onCreate
        self.onCancel = onCancel
        _patternText = State(initialValue: initialPattern)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    patternCard
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Categorizza sempre così")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea", action: submit)
                        .disabled(isCreating || trimmedPattern.isEmpty)
                }
            }
        }
    }

    private var patternCard: some View {
        Card {
            EyebrowLabel(text: "Assegna \"\(categoryName)\" quando la descrizione")
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

    private var trimmedPattern: String {
        patternText.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        guard !trimmedPattern.isEmpty else { return }
        onCreate(matchKind, trimmedPattern)
    }
}
