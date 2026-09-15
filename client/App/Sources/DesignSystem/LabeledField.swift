import SwiftUI

/// The `EyebrowLabel` + text-input pattern every create/edit sheet repeats
/// for a single-purpose field living in its own `Card` — a name, an amount,
/// a match pattern, a currency code (`CreateManualAccountSheet`'s alias and
/// currency fields are the pattern this was extracted from). Handles the
/// styling boilerplate every call site duplicated by hand
/// (`.autocorrectionDisabled()`, the iOS-only keyboard/capitalization
/// tweaks); the caller still owns the surrounding `Card` and the field's
/// semantics (validation, formatting, `onChange`).
///
/// Not for a dense multi-field card (the Server settings card's URL + token
/// pair uses a smaller caption label and several fields per card) — that
/// stays its own layout.
struct LabeledField: View {
    let eyebrow: String
    let placeholder: String
    @Binding var text: String
    /// `true` for a secret (the API token) — renders a `SecureField`.
    var isSecure: Bool = false
    var font: Font = Typography.statFigure
    #if os(iOS)
        var keyboardType: UIKeyboardType = .default
        var autocapitalization: TextInputAutocapitalization = .sentences
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EyebrowLabel(text: eyebrow)
            fieldBody
                .font(font)
                .foregroundStyle(Palette.ink)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(autocapitalization)
                    .keyboardType(keyboardType)
                #endif
        }
    }

    @ViewBuilder
    private var fieldBody: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}
