import Foundation
import Testing

@testable import Traccio

/// Tests for `AppLock` against `FakeBiometricAuthenticator` — never the real
/// platform default, so no test can ever trigger an actual system prompt
/// (`BiometricAuthenticating`'s own doc comment explains why that would hang
/// `xcodebuild test`).
@MainActor
struct AppLockTests {
    /// Mirrors `AppLock`'s own private `preferenceKey` — duplicated here
    /// deliberately, the same way other tests assert on a literal wire value
    /// rather than importing the production constant.
    private static let preferenceKey = "lock.biometricEnabled"

    private func makeLock(
        enabled: Bool = false,
        available: Bool = true,
        biometry: BiometryKind = .faceID,
        result: Result<Void, BiometricAuthError> = .success(())
    ) async -> (lock: AppLock, fake: FakeBiometricAuthenticator) {
        let defaults = UserDefaults(suiteName: "AppLockTests.\(UUID())")!
        if enabled {
            defaults.set(true, forKey: Self.preferenceKey)
        }
        let fake = FakeBiometricAuthenticator(isAvailable: available, biometry: biometry)
        await fake.setResult(result)
        return (AppLock(authenticator: fake, defaults: defaults), fake)
    }

    // MARK: Startup

    @Test func startsUnlockedWhenThePreferenceIsAbsent() async {
        let (lock, _) = await makeLock(enabled: false)
        #expect(lock.state == .unlocked)
        #expect(lock.isEnabled == false)
    }

    @Test func startsLockedWhenThePreferenceIsOn() async {
        let (lock, _) = await makeLock(enabled: true)
        #expect(lock.state == .locked)
        #expect(lock.isEnabled == true)
    }

    // MARK: Scene phase transitions

    @Test func backgroundLocksWhenEnabled() async {
        let (lock, _) = await makeLock(enabled: true)
        await lock.authenticate()
        #expect(lock.state == .unlocked)

        await lock.handleScenePhase(.background)

        #expect(lock.state == .locked)
    }

    @Test func backgroundDoesNotLockWhenDisabled() async {
        let (lock, _) = await makeLock(enabled: false)

        await lock.handleScenePhase(.background)

        #expect(lock.state == .unlocked)
    }

    @Test func inactiveNeverLocksEvenWhenEnabled() async {
        // The system prompt itself drives the app to .inactive while it's on
        // screen — locking on .inactive would fight the prompt just raised.
        let (lock, _) = await makeLock(enabled: true)
        await lock.authenticate()
        #expect(lock.state == .unlocked)

        await lock.handleScenePhase(.inactive)

        #expect(lock.state == .unlocked)
    }

    @Test func returningActiveAuthenticatesOnceWhenLocked() async {
        let (lock, fake) = await makeLock(enabled: true)  // cold start: already .locked

        await lock.handleScenePhase(.active)

        #expect(lock.state == .unlocked)
        #expect(await fake.callCount == 1)
    }

    @Test func returningActiveDoesNothingWhenAlreadyUnlocked() async {
        let (lock, fake) = await makeLock(enabled: false)

        await lock.handleScenePhase(.active)

        #expect(lock.state == .unlocked)
        #expect(await fake.callCount == 0)
    }

    // MARK: Authentication outcomes

    @Test func authenticateSuccessUnlocks() async {
        let (lock, _) = await makeLock(enabled: true)

        await lock.authenticate()

        #expect(lock.state == .unlocked)
    }

    @Test func authenticateFailureSetsFailed() async {
        let (lock, _) = await makeLock(enabled: true, result: .failure(.failed))

        await lock.authenticate()

        #expect(lock.state == .failed(.failed))
    }

    @Test func cancelLeavesFailedAndDoesNotAutoRetryOnASecondActiveTransition() async {
        let (lock, fake) = await makeLock(enabled: true, result: .failure(.cancelled))

        await lock.handleScenePhase(.background)
        await lock.handleScenePhase(.active)  // auto-authenticates, cancels

        #expect(lock.state == .failed(.cancelled))
        #expect(await fake.callCount == 1)

        // A further .active with no background in between (e.g. dismissing
        // the cancelled system sheet) must not re-prompt on its own.
        await lock.handleScenePhase(.active)

        #expect(lock.state == .failed(.cancelled))
        #expect(await fake.callCount == 1)
    }

    @Test func manualRetryAfterFailureUnlocks() async {
        let (lock, fake) = await makeLock(enabled: true, result: .failure(.failed))
        await lock.authenticate()
        #expect(lock.state == .failed(.failed))

        await fake.setResult(.success(()))
        await lock.authenticate()

        #expect(lock.state == .unlocked)
    }

    @Test func authenticateIsIgnoredWhileAlreadyAuthenticating() async {
        let (lock, fake) = await makeLock(enabled: true)
        await fake.gateNextCall()

        let inFlight = Task { await lock.authenticate() }
        // authenticate() sets .authenticating synchronously before awaiting
        // the (gated) fake call, so this loop terminates without a real delay.
        while lock.state != .authenticating {
            await Task.yield()
        }

        // A second call while the first is still in flight must be a no-op.
        await lock.authenticate()
        #expect(await fake.callCount == 0)

        await fake.releaseGatedCall()
        await inFlight.value

        #expect(lock.state == .unlocked)
        #expect(await fake.callCount == 1)
    }

    // MARK: Escape hatches

    @Test func continueWithoutLockUnlocksAndDisablesThePreference() async {
        let (lock, _) = await makeLock(enabled: true, available: false)
        #expect(lock.state == .locked)

        lock.continueWithoutLock()

        #expect(lock.state == .unlocked)
        #expect(lock.isEnabled == false)
    }

    @Test func disablingWhileLockedUnlocksImmediately() async {
        let (lock, _) = await makeLock(enabled: true)
        #expect(lock.state == .locked)

        lock.isEnabled = false

        #expect(lock.state == .unlocked)
    }

    @Test func enablingWhileUnlockedDoesNotPromptImmediately() async {
        let (lock, fake) = await makeLock(enabled: false)

        lock.isEnabled = true

        #expect(lock.state == .unlocked)
        #expect(await fake.callCount == 0)
    }

    // MARK: Persistence

    @Test func enablingPersistsToTheInjectedDefaults() async {
        let defaults = UserDefaults(suiteName: "AppLockTests.\(UUID())")!
        let lock = AppLock(authenticator: FakeBiometricAuthenticator(), defaults: defaults)

        lock.isEnabled = true

        #expect(defaults.bool(forKey: Self.preferenceKey) == true)
    }

    @Test func disablingPersistsToTheInjectedDefaults() async {
        let defaults = UserDefaults(suiteName: "AppLockTests.\(UUID())")!
        defaults.set(true, forKey: Self.preferenceKey)
        let lock = AppLock(authenticator: FakeBiometricAuthenticator(), defaults: defaults)

        lock.isEnabled = false

        #expect(defaults.bool(forKey: Self.preferenceKey) == false)
    }
}
