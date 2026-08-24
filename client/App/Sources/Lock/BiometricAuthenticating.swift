import Foundation

/// How `AppLock` asks the device to verify the owner.
///
/// A protocol, not a direct `LAContext` call, for the same reason
/// `APIClientProtocol` exists: `LocalAuthentication` cannot be exercised in
/// `xcodebuild test` without raising a real system prompt (which would hang
/// the test run waiting for input nothing can provide) — `AppLock`'s tests
/// inject `FakeBiometricAuthenticator` (`App/Tests/`) instead, the same
/// fake-in-test-target split `FakeAPIClient` already establishes.
///
/// No error crossing this seam carries a raw system message —
/// `BiometricAuthError` is a closed, value-free enum, per
/// `.claude/rules/data-safety.md`'s "never re-raise a provider exception
/// unchanged" posture applied to a platform framework instead of a network
/// provider.
protocol BiometricAuthenticating: Sendable {
    /// Whether `.deviceOwnerAuthentication` can be evaluated at all right
    /// now. `false` when the device has no passcode set — the one case the
    /// OS itself cannot rescue with a fallback, since there is nothing to
    /// fall back to (`AppLock.continueWithoutLock()` is the app's own
    /// escape hatch for that case).
    var isAvailable: Bool { get }

    /// Which kind of biometry this device offers, for the lock screen's
    /// copy ("Sblocca con Face ID" vs "Sblocca con Touch ID"). `.none` when
    /// the device has a passcode but no enrolled biometry — authentication
    /// still works, `.deviceOwnerAuthentication` falls straight to the
    /// passcode sheet.
    var biometry: BiometryKind { get }

    /// Evaluate `.deviceOwnerAuthentication`, prompting the user.
    ///
    /// - Parameter reason: Shown in the system prompt alongside the app
    ///   name (the `localizedReason` `LAContext.evaluatePolicy` requires).
    /// - Throws: `BiometricAuthError` — never the underlying `LAError`.
    func authenticate(reason: String) async throws(BiometricAuthError)
}

/// Which biometry, if any, this device offers.
enum BiometryKind: Equatable, Sendable {
    case faceID
    case touchID
    /// A passcode-only device (or one this app cannot yet describe) — still
    /// usable with `.deviceOwnerAuthentication`, just no biometric label.
    case none
}

/// A stable, value-free authentication outcome — never a raw `LAError` or
/// its `localizedDescription` (`.claude/rules/data-safety.md`).
enum BiometricAuthError: Error, Equatable, Sendable {
    /// The user cancelled the prompt, or the app was interrupted (backgrounded
    /// mid-prompt, another app requested authentication first).
    case cancelled
    /// `.deviceOwnerAuthentication` cannot be evaluated at all — no
    /// passcode set, or biometry locked out/not enrolled with no passcode
    /// fallback possible on this OS version.
    case unavailable
    /// Evaluation ran and did not succeed for any other reason.
    case failed
}

/// The authenticator used wherever biometric lock cannot actually work: the
/// macOS build (the feature is iOS-only — see `docs/decisions/0013-biometric-lock.md`)
/// and SwiftUI previews. `isAvailable` is always `false`, so `AppLock` never
/// enters a state that expects a prompt to fire.
struct UnavailableBiometricAuthenticator: BiometricAuthenticating {
    var isAvailable: Bool { false }
    var biometry: BiometryKind { .none }

    func authenticate(reason: String) async throws(BiometricAuthError) {
        throw .unavailable
    }
}
