import SwiftUI
import TraccioCore

/// "Nuova categoria" / "Rinomina categoria" — one sheet for both, since the
/// two forms differ only in title, prefill, and which write they trigger on
/// submit.
struct CategoryEditorSheet: View {
    /// Which write this sheet performs. Modeled as an enum rather than an
    /// optional `CategoryResponse` plus a boolean flag, so "editing nothing"
    /// is unrepresentable (`.claude/rules/swift.md`).
    enum Mode {
        case create
        case rename(CategoryResponse)
    }

    let mode: Mode
    var isSaving: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the trimmed name once the user submits a valid form.
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var nameText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    Card {
                        EyebrowLabel(text: "Nome")
                        TextField("Es. Alimentari", text: $nameText)
                            .font(Typography.statFigure)
                            .foregroundStyle(Palette.ink)
                            .autocorrectionDisabled()
                    }
                }
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: submit)
                        .disabled(isSaving || trimmedName.isEmpty)
                }
            }
        }
        .onAppear {
            if case .rename(let category) = mode, nameText.isEmpty {
                nameText = category.name
            }
        }
    }

    private var title: String {
        switch mode {
        case .create: "Nuova categoria"
        case .rename: "Rinomina categoria"
        }
    }

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
    }
}
