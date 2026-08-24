import SwiftUI
import TraccioCore

/// The Impostazioni tab — the container for every settings-shaped screen
/// this app has or will have (ADR 0009). "Categorie e regole" is the first
/// and only entry today; Eventi (an entire M2 backend with no client
/// surface yet), biometric lock, and backup/export are tracked in
/// `tasks/backlog.md` as later entries here.
///
/// No mockup covers this screen (`docs/design/canvas/` mocks only
/// Panoramica/Movimenti/Conti/Dettaglio) — a fourth tab is a deliberate
/// divergence from the canvas, recorded in ADR 0009 rather than left to
/// drift silently (ADR 0008's "Revisit when"). Built from the same `Card`
/// row idiom as every other screen, not a stock `List`, so it does not
/// reintroduce the plain-row look ADR 0008 replaced.
struct SettingsView: View {
    @Environment(DataFreshness.self) private var freshness

    var body: some View {
        NavigationStack {
            ScrollView {
                Card {
                    NavigationLink {
                        CategorizationView(
                            onSuggestionsChanged: { freshness.markStale([.dashboard, .transactions]) }
                        )
                    } label: {
                        settingsRow(title: "Categorie e regole", systemImage: "tag")
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Impostazioni")
        }
    }

    private func settingsRow(title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 28, height: 28)
                .background(Palette.neutralFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.inkQuaternary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    SettingsView()
        .environment(DataFreshness())
}
