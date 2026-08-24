import SwiftUI

/// The app's biometric-lock state, driven by `ScenePhase` — see
/// `docs/decisions/0013-biometric-lock.md`.
///
/// `.unlocked` — the app is usable; the default state, and the only state
/// the lock feature is disabled ever settles into.
/// `.locked` — needs authentication, no prompt in flight, no prior failure.
/// The state a cold launch starts in when the preference is on, and the
/// state a background→foreground round trip resets to.
/// `.authenticating` — the system prompt is on screen.
/// `.failed(_)` — the user cancelled, or authentication failed outright.
/// Deliberately does **not** auto-retry on the next `.active` — only
/// `.locked` does — so a cancelled prompt does not loop back at the user the
/// moment they return to the app; `AppLock.authenticate()` is the retry.
enum LockState: Equatable {
    case unlocked
    case locked
    case authenticating
    case failed(BiometricAuthError)
}

/// The app-wide biometric lock: whether it's enabled, and the current
/// `LockState`. Owned by `TraccioApp` and injected once via `.environment(_:)`
/// — same placement and shape as `DataFreshness`, the client's only other
/// app-level `@Observable`.
///
/// Feature is iOS-only (`docs/decisions/0013-biometric-lock.md`); this type
/// itself has no platform guard so it keeps compiling and testing under
/// `make test-app`'s macOS host — only the UI (`Lock/LockScreenView.swift`
/// and friends) and the real `LocalAuthenticationAuthenticator` are
/// `#if os(iOS)`. On macOS, `authenticator.isAvailable` is always `false`
/// (`UnavailableBiometricAuthenticator`), so `state` can never leave
/// `.unlocked` there regardless of the stored preference.
@MainActor
@Observable
final class AppLock {
    /// Shown in the system authentication prompt, alongside the app name.
    private static let authenticationReason = "Sblocca Traccio per vedere i tuoi conti."

    /// `UserDefaults` key for the enabled preference. The client's first use
    /// of `UserDefaults`: a plain `Bool` is not financial data
    /// (`.claude/rules/data-safety.md` restricts *financial* data, not every
    /// preference), so this is a deliberate, narrow exception, not a crack in
    /// the rule. Not Keychain-backed: an attacker with device access could
    /// flip this key directly, accepted as YAGNI for a personal, single-user
    /// app (see the ADR's "Alternatives considered").
    private static let preferenceKey = "lock.biometricEnabled"

    private let authenticator: any BiometricAuthenticating
    private let defaults: UserDefaults

    private(set) var state: LockState

    /// Backing store for `isEnabled`, a plain stored property so
    /// `@Observable`'s access tracking covers it directly — `isEnabled`
    /// itself stays a computed wrapper around this plus the `UserDefaults`
    /// write, rather than mixing `didSet` side effects into a tracked
    /// stored property.
    private var isEnabledStorage: Bool

    /// Whether the user has opted into biometric lock. Off by default
    /// (absent key → `false`, no registration needed). Setting `false`
    /// unlocks immediately — disabling the feature must never strand the
    /// user behind their own lock screen. Setting `true` does **not** lock
    /// immediately: the user is holding an already-unlocked app, and the
    /// lock takes effect on the next background→foreground round trip.
    var isEnabled: Bool {
        get { isEnabledStorage }
        set {
            isEnabledStorage = newValue
            defaults.set(newValue, forKey: Self.preferenceKey)
            if !newValue {
                state = .unlocked
            }
        }
    }

    /// Whether `.deviceOwnerAuthentication` can be evaluated on this device
    /// right now — `false` gates the Impostazioni toggle off with an
    /// explanatory caption (no passcode set on the device).
    var isBiometryAvailable: Bool { authenticator.isAvailable }

    /// Which biometry this device offers — drives the lock screen's icon
    /// (`faceid`/`touchid`/`lock.fill`).
    var biometryKind: BiometryKind { authenticator.biometry }

    /// Display name for the lock screen's button copy ("Sblocca con Face ID").
    var biometryName: String {
        switch authenticator.biometry {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .none: "codice"
        }
    }

    /// - Parameters:
    ///   - authenticator: Defaults to the real platform authenticator
    ///     (`UnavailableBiometricAuthenticator` on macOS). Tests always pass
    ///     `FakeBiometricAuthenticator` explicitly — never the default —
    ///     so a test can never trigger a real system prompt.
    ///   - defaults: Defaults to `.standard`. Tests pass a throwaway named
    ///     suite so runs don't share state.
    init(
        authenticator: any BiometricAuthenticating = BiometricAuthenticator.platformDefault,
        defaults: UserDefaults = .standard
    ) {
        self.authenticator = authenticator
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.preferenceKey)
        self.isEnabledStorage = enabled
        // A cold launch with the preference on starts locked, so the lock
        // screen is what renders first — never a frame of real content.
        self.state = enabled ? .locked : .unlocked
    }

    /// React to a `ScenePhase` change. Called from `LockOverlayModifier`'s
    /// `.onChange(of: scenePhase)`.
    ///
    /// `.inactive` is deliberately a no-op here: the system authentication
    /// prompt itself drives the app to `.inactive` while it's on screen, so
    /// treating `.inactive` as "went to background" would fight the very
    /// prompt `authenticate()` just raised. Locking is keyed to the fuller
    /// `.background` transition; the privacy cover (a separate, unconditional
    /// concern — see `LockOverlayModifier`) is what actually reacts to
    /// `.inactive`.
    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            if isEnabled {
                // Unconditional: also resets a stale .failed from before
                // backgrounding, so returning to the app always offers a
                // fresh prompt rather than a stuck error message.
                state = .locked
            }
        case .active:
            if state == .locked {
                await authenticate()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Trigger (or retry) authentication. No-op unless `state` is `.locked`
    /// or `.failed` — in particular, a no-op while `.authenticating`, so a
    /// stray second call can never race a prompt already on screen.
    func authenticate() async {
        guard state == .locked || isFailed else { return }
        state = .authenticating
        do {
            try await authenticator.authenticate(reason: Self.authenticationReason)
            state = .unlocked
        } catch {
            state = .failed(error)
        }
    }

    /// The one escape hatch the OS itself cannot provide: the preference is
    /// on, but the device has no passcode at all, so every evaluation throws
    /// `.unavailable` with no fallback to offer. Turns the feature off and
    /// unlocks — surfaced only from the lock screen's `.failed(.unavailable)`
    /// branch.
    func continueWithoutLock() {
        isEnabled = false
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
