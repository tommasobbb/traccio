#if os(iOS)
import SwiftUI

/// Owns the root-level `scenePhase` observation and the `ZStack` that
/// presents `LockScreenView`/`PrivacyCoverView` over the rest of the app, so
/// `TraccioApp.swift` stays a small, declarative diff. See
/// `docs/decisions/0013-biometric-lock.md`.
///
/// Two independent concerns share this one `scenePhase` observer:
/// - **Privacy cover** — shown whenever `scenePhase != .active`, entirely
///   unconditional on `AppLock.isEnabled`. Addresses
///   `docs/engineering.md`'s app-switcher-snapshot note on its own,
///   for every user, whether or not they ever turn biometric lock on.
/// - **Lock screen** — shown whenever `AppLock.state != .unlocked`, which
///   only happens at all when the preference is on.
///
/// The content beneath stays mounted the whole time (a `ZStack`, not a
/// state-switched root view): every tab's own `.task`/`.onChange(of:
/// scenePhase)` — notably `AccountsView`'s post-bank-re-auth refresh — keeps
/// running underneath, and tab/scroll state survives a lock/unlock cycle.
struct LockOverlayModifier: ViewModifier {
    let lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        ZStack {
            content
                .allowsHitTesting(!isCovered)
                .accessibilityHidden(isCovered)
            if lock.state != .unlocked {
                LockScreenView(lock: lock)
                    .ignoresSafeArea()
            } else if showsPrivacyCover {
                PrivacyCoverView()
                    .ignoresSafeArea()
                    // No transition on the way in: the app-switcher snapshot
                    // is captured right as scenePhase leaves .active, and a
                    // fade would be caught mid-transparency, defeating the
                    // point. Fading back out on return to .active is fine.
                    .transition(.identity)
            }
        }
        .animation(.default, value: lock.state)
        .onChange(of: scenePhase) { _, phase in
            Task { await lock.handleScenePhase(phase) }
        }
    }

    /// The lock screen itself counts as "covered" content for hit-testing
    /// purposes, but never needs the plain privacy cover drawn behind it —
    /// excluding `.authenticating` here stops the cover flashing over the
    /// lock screen while the system prompt holds the app `.inactive`.
    private var showsPrivacyCover: Bool {
        scenePhase != .active && lock.state != .authenticating
    }

    private var isCovered: Bool {
        lock.state != .unlocked || scenePhase != .active
    }
}

extension View {
    /// Gate this view behind `AppLock`'s privacy cover and lock screen. Apply
    /// once, at the root (`TraccioApp`).
    func appLockOverlay(_ lock: AppLock) -> some View {
        modifier(LockOverlayModifier(lock: lock))
    }
}
#endif
