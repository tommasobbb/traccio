import SwiftUI
import TraccioCore

/// App entry point. Presentation only — a four-tab shell (Panoramica,
/// Movimenti, Conti, Impostazioni; ADR 0009 records the fourth tab's
/// addition), gated behind `OnboardingView` until the server is configured.
/// All logic lives in the TraccioCore package.
@main
struct TraccioApp: App {
    /// Shared cross-tab invalidation signal — see `DataFreshness`'s
    /// docstring. Owned here so every tab observes the same instance.
    @State private var freshness = DataFreshness()
    /// Biometric lock state, iOS-only in effect (`docs/decisions/0013-biometric-lock.md`)
    /// but not gated itself — see `AppLock`'s own doc comment. Injected
    /// unconditionally so `SettingsView` can read it without conditionally
    /// declaring the environment.
    @State private var lock = AppLock()
    /// Whether `TabView` should render at all. Read once at launch from
    /// `ServerConfigurationStore.isConfigured`, not re-checked continuously —
    /// `OnboardingView` flips it via `onComplete` the moment it saves a
    /// working configuration. This is also what makes onboarding sidestep
    /// ADR 0014's "restart to apply" limitation: `TabView` and every view
    /// model inside it are not constructed until this becomes `true`, so
    /// their `= APIClient.current` default parameters read the freshly
    /// saved configuration on their very first construction.
    @State private var isConfigured = ServerConfigurationStore.shared.isConfigured

    var body: some Scene {
        WindowGroup {
            if isConfigured {
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
                .environment(lock)
                #if os(iOS)
                .appLockOverlay(lock)
                #endif
            } else {
                OnboardingView { isConfigured = true }
            }
        }
    }
}
