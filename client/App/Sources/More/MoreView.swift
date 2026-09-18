import SwiftUI
import TraccioCore

/// The "Altro" tab — the container for every *feature* screen that doesn't
/// fit the three daily-use tabs (Panoramica, Movimenti, Conti) but is a real
/// thing the user does, not a setting: Eventi, Anticipi, Categorie e regole.
/// Revises ADR 0009's fourth tab (`docs/decisions/0033-more-tab-and-settings-corner.md`) —
/// the settings-shaped screens that ADR named as this tab's reason for
/// existing (Inizio tracciamento, biometric lock, backup/export) moved to
/// `SettingsView`, now reached from Panoramica's own toolbar instead of the
/// dock, once it became clear the tab had grown two different kinds of
/// content: things you *do* and things you *configure*.
///
/// Built from the same `Card` row idiom as `SettingsView` and every other
/// screen — not a stock `List` — so it does not reintroduce the plain-row
/// look ADR 0008 replaced.
struct MoreView: View {
    @Environment(DataFreshness.self) private var freshness

    var body: some View {
        NavigationStack {
            ScrollView {
                Card {
                    NavigationLink {
                        EventsView()
                    } label: {
                        row(title: "Eventi", systemImage: "calendar")
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Palette.separator)
                    NavigationLink {
                        AdvancesView()
                    } label: {
                        row(title: "Anticipi", systemImage: "person.2")
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Palette.separator)
                    NavigationLink {
                        CategorizationView(
                            onSuggestionsChanged: { freshness.markStale([.dashboard, .transactions]) }
                        )
                    } label: {
                        row(title: "Categorie e regole", systemImage: "tag")
                    }
                    .buttonStyle(.plain)
                }
                .padding(Spacing.gutter)
            }
            .screenChrome("Altro", style: .tabRoot)
        }
    }

    private func row(title: String, systemImage: String) -> some View {
        HStack(spacing: Spacing.itemGap) {
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
            DisclosureChevron()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    MoreView()
        .environment(DataFreshness())
}
