import SwiftUI

/// App entry point. Presentation only — a two-tab shell (Panoramica, Conti).
/// All logic lives in the TraccioCore package.
///
/// Two tabs, not three: Movimenti has no screen yet (needs `GET /transactions`
/// and its models — a later M3 slice), and an empty placeholder tab wouldn't
/// add anything. `AccountsView` keeps its M0 look until its own restyle slice
/// (ADR 0008) — a one-slice visual inconsistency between tabs is a smaller
/// cost than restyling two screens in one task.
@main
struct TraccioApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem {
                        Label("Panoramica", systemImage: "square.grid.2x2")
                    }
                AccountsView()
                    .tabItem {
                        Label("Conti", systemImage: "creditcard")
                    }
            }
        }
    }
}
