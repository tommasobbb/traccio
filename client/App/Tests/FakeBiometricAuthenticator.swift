@testable import Traccio

/// A fake `BiometricAuthenticating` for `AppLock` tests — no real system
/// prompt, ever.
///
/// An `actor`, same reasoning as `FakeAPIClient`: `BiometricAuthenticating`
/// requires `Sendable`, and an actor gets that for free while still letting
/// a test configure the outcome safely across `await` boundaries. Lives in
/// the test target, never in production code — `AppLock()`'s default
/// initializer always resolves to `BiometricAuthenticator.platformDefault`,
/// never this type.
actor FakeBiometricAuthenticator: BiometricAuthenticating {
    nonisolated let isAvailable: Bool
    nonisolated let biometry: BiometryKind

    /// What `authenticate(reason:)` returns — `.success` unlocks, any
    /// failure case is thrown as the matching `BiometricAuthError`. Defaults
    /// to success so a test that doesn't care configures nothing.
    var resultToReturn: Result<Void, BiometricAuthError> = .success(())

    /// How many times `authenticate(reason:)` was actually called — the
    /// re-entrancy and no-auto-retry tests assert on this rather than on
    /// `state` alone, since a bug that fires the prompt twice would leave
    /// `state` looking correct either way.
    private(set) var callCount = 0

    /// When set, the next `authenticate(reason:)` call suspends until
    /// `releaseGatedCall()` is invoked — the only way to deterministically
    /// observe `AppLock` mid-`.authenticating` in a test (a real prompt has
    /// no such hook; a real `authenticate()` call is otherwise
    /// near-instantaneous, so a re-entrancy test would race it).
    private var isGated = false
    private var gate: CheckedContinuation<Void, Never>?

    init(isAvailable: Bool = true, biometry: BiometryKind = .faceID) {
        self.isAvailable = isAvailable
        self.biometry = biometry
    }

    func setResult(_ result: Result<Void, BiometricAuthError>) {
        resultToReturn = result
    }

    func gateNextCall() {
        isGated = true
    }

    func releaseGatedCall() {
        gate?.resume()
        gate = nil
    }

    func authenticate(reason: String) async throws(BiometricAuthError) {
        if isGated {
            isGated = false
            await withCheckedContinuation { continuation in gate = continuation }
        }
        callCount += 1
        switch resultToReturn {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}
