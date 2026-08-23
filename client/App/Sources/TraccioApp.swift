import SwiftUI

/// App entry point. Presentation only — a three-tab shell (Panoramica,
/// Movimenti, Conti). All logic lives in the TraccioCore package.
@main
struct TraccioApp: App {
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
            }
        }
    }
}
