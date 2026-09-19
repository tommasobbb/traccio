import SwiftUI

/// A person's initials disc. Neutral ink-on-fill — an avatar is identity, not
/// a control (`docs/design/tokens.md`'s "Accent dosage"), so it never carries
/// the app's accent or a `PaletteColor`.
///
/// Promoted from a private helper on `AdvanceSections` (2026-09-19) to a
/// shared component once `AdvancesView`'s own rows needed the same leading
/// element — the only lists in the app that had none.
struct InitialsAvatar: View {
    let name: String
    var diameter: CGFloat = 36

    var body: some View {
        Text(initials)
            .font(Typography.caption.weight(.bold))
            .foregroundStyle(Palette.inkSecondary)
            .frame(width: diameter, height: diameter)
            .background(Palette.neutralFill)
            .clipShape(Circle())
    }

    /// The first letter of up to two words ("Marco Rossi" → "MR"), or one for
    /// a single-word name — `AdvanceSections`' original only ever took the
    /// first word's first letter, which read as anonymous for the common case
    /// of a full name.
    private var initials: String {
        let letters =
            name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        guard !letters.isEmpty else { return "?" }
        return String(letters).uppercased()
    }
}
