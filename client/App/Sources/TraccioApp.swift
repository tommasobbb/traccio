import SwiftUI
import TraccioCore

/// App entry point. Presentation only — a four-tab shell (Panoramica,
/// Movimenti, Conti, Impostazioni; ADR 0009 records the fourth tab's
/// addition), gated behind `OnboardingView` until the server is configured.
/// All logic lives in the TraccioCore package.
@main
struct TraccioApp: App {
    /// Identifies each tab, for the drill-through's tab switch below —
    /// `TabView`'s own `.tag(_:)` needs a `Hashable` value distinct from
    /// each tab's `View` type.
    private enum Tab: Hashable {
        case dashboard, transactions, accounts, settings
    }

    /// Shared cross-tab invalidation signal — see `DataFreshness`'s
    /// docstring. Owned here so every tab observes the same instance.
    @State private var freshness = DataFreshness()
    /// Biometric lock state, iOS-only in effect (`docs/decisions/0013-biometric-lock.md`)
    /// but not gated itself — see `AppLock`'s own doc comment. Injected
    /// unconditionally so `SettingsView` can read it without conditionally
    /// declaring the environment.
    @State private var lock = AppLock()
    /// Panoramica's category drill-through into a pre-filtered Movimenti —
    /// see `TransactionsDrillThrough`'s own doc comment for why this needs a
    /// tab switch plus an `.id(_:)`-forced rebuild rather than a plain push.
    @State private var drillThrough = TransactionsDrillThrough()
    /// Which tab `TabView` shows. Plain `@State`, not part of
    /// `TransactionsDrillThrough`, since `TraccioApp` is the only thing that
    /// ever needs to *read* it (as the `TabView` selection binding); every
    /// other view only ever *requests* a drill-through, never a tab directly.
    @State private var selectedTab: Tab = .dashboard
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
                TabView(selection: $selectedTab) {
                    DashboardView()
                        .tabItem {
                            // `chart.bar` rhymes with the app icon's three
                            // ascending bars and has a `.fill` variant, so the
                            // active tab actually lights up.
                            Label("Panoramica", systemImage: "chart.bar")
                        }
                        .tag(Tab.dashboard)
                    TransactionsView(initialFilter: drillThrough.filter)
                        .id(drillThrough.generation)
                        .tabItem {
                            // `list.bullet` has no filled counterpart, so it
                            // was the one tab that never lit when selected;
                            // `list.bullet.rectangle.portrait` does.
                            Label("Movimenti", systemImage: "list.bullet.rectangle.portrait")
                        }
                        .tag(Tab.transactions)
                    AccountsView()
                        .tabItem {
                            Label("Conti", systemImage: "creditcard")
                        }
                        .tag(Tab.accounts)
                    SettingsView()
                        .tabItem {
                            Label("Impostazioni", systemImage: "gearshape")
                        }
                        .tag(Tab.settings)
                }
                .environment(freshness)
                .environment(lock)
                .environment(drillThrough)
                .onChange(of: drillThrough.generation) { _, _ in selectedTab = .transactions }
                #if os(iOS)
                .appLockOverlay(lock)
                #endif
            } else {
                OnboardingView { isConfigured = true }
            }
        }
    }
}
