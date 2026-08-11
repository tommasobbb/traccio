import SwiftUI

/// App entry point. Presentation only — a single window showing the accounts
/// list. All logic lives in the TraccioCore package.
@main
struct TraccioApp: App {
    var body: some Scene {
        WindowGroup {
            AccountsView()
        }
    }
}
