import Foundation

#if os(iOS)
import LocalAuthentication

/// The real `BiometricAuthenticating`, backed by `LAContext`. iOS only —
/// biometric lock is scoped to the iPhone trial
/// (`docs/decisions/0013-biometric-lock.md`); the macOS build never
/// constructs this type.
struct LocalAuthenticationAuthenticator: BiometricAuthenticating {
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometry: BiometryKind {
        let context = LAContext()
        // canEvaluatePolicy must run before biometryType is meaningful —
        // an unqueried context reports .none regardless of the hardware.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    func authenticate(reason: String) async throws(BiometricAuthError) {
        // A fresh LAContext per call, deliberately never reused: a context
        // that already evaluated successfully caches that outcome and would
        // let a second unlock through with no prompt at all.
        if let error = await evaluate(LAContext(), reason: reason) {
            throw error
        }
    }

    /// - Returns: `nil` on success, or the mapped failure.
    private func evaluate(_ context: LAContext, reason: String) async -> BiometricAuthError? {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
                success, error in
                continuation.resume(returning: success ? nil : Self.map(error))
            }
        }
    }

    /// Map an `LAError` to the stable, value-free outcome `AppLock` sees —
    /// never the raw `LAError`/`localizedDescription`
    /// (`docs/engineering.md`).
    private static func map(_ error: Error?) -> BiometricAuthError {
        guard let laError = error as? LAError else { return .failed }
        switch laError.code {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
            return .unavailable
        default:
            return .failed
        }
    }
}
#endif

/// The authenticator to use on this platform — the same injectable-default
/// idiom as `APIClient.current`
/// (`client/App/Sources/APIClient+Default.swift`). Not gated itself: it must
/// resolve to something on every platform this target builds for, so
/// `AppLock()`'s default initializer compiles on macOS too.
enum BiometricAuthenticator {
    static let platformDefault: any BiometricAuthenticating = {
        #if os(iOS)
        LocalAuthenticationAuthenticator()
        #else
        // Biometric lock is iOS-only (docs/decisions/0013-biometric-lock.md):
        // the macOS build reports unavailable rather than ever prompting.
        UnavailableBiometricAuthenticator()
        #endif
    }()
}
