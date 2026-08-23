import SwiftUI

/// App entry point. Presentation only — a three-tab shell (Panoramica,
/// Movimenti, Conti). All logic lives in the TraccioCore package.
///
/// `AccountsView` keeps its M0 look until its own restyle slice (ADR 0008) —
/// a one-slice visual inconsistency between tabs is a smaller cost than
/// restyling two screens in one task.
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
