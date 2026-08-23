import SwiftUI

/// App entry point. Presentation only — a four-tab shell (Panoramica,
/// Movimenti, Conti, Impostazioni; ADR 0009 records the fourth tab's
/// addition). All logic lives in the TraccioCore package.
@main
struct TraccioApp: App {
    /// Shared cross-tab invalidation signal — see `DataFreshness`'s
    /// docstring. Owned here so every tab observes the same instance.
    @State private var freshness = DataFreshness()

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem {
                        Label("Panoramica", systemImage: "square.grid.2x2")
                    }
                TransactionsView()
                    .tabItem {
                        Label("Movimenti", systemImage: "list.bullet")
                    }
                AccountsView()
                    .tabItem {
                        Label("Conti", systemImage: "creditcard")
                    }
                SettingsView()
                    .tabItem {
                        Label("Impostazioni", systemImage: "gearshape")
                    }
            }
            .environment(freshness)
        }
    }
}
