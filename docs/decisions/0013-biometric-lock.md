# 0013 — Biometric lock: iOS-only, `.deviceOwnerAuthentication`, off by default

Status: accepted
Date: 2026-08-25

## Context

Point 5 of the M3 "iPhone trial" roadmap (`tasks/backlog.md`): the app now
carries real financial data on a phone that leaves the house, and nothing
protects it. Two gaps existed before this slice: no gate at launch or on
return from the background, and `docs/engineering.md`'s own
reminder — "consider what appears in the app switcher snapshot when the app
is backgrounded" — had no code behind it at all. There was also no
`UserDefaults` usage, no `LocalAuthentication` usage, and no root-level
`@Environment(\.scenePhase)` observer anywhere in the client before this.

## Decision

**1. iOS only.** The client target is universal (iOS 17+ / macOS 14+, one
XcodeGen target, `client/Project.yml`), but the macOS build is unsigned today
(`CODE_SIGNING_ALLOWED[sdk=macosx*]: "NO"` — no Apple Developer team yet), and
the roadmap's own framing is explicitly an *iPhone* trial. Every UI type and
every call into `LocalAuthentication` sits behind `#if os(iOS)`
(`LocalAuthenticationAuthenticator.swift`, `LockScreenView.swift`,
`PrivacyCoverView.swift`, `LockOverlayModifier.swift`, plus the two
conditional blocks in `TraccioApp.swift` and `SettingsView.swift`). The state
machine itself (`AppLock`, `LockState`, `BiometricAuthenticating`) is
deliberately **not** gated — it is plain Swift plus `SwiftUI.ScenePhase`, so
it keeps compiling and running under `make test-app`'s macOS test host. On
macOS, `BiometricAuthenticator.platformDefault` resolves to
`UnavailableBiometricAuthenticator` (`isAvailable == false`), so `AppLock`
can never leave `.unlocked` there regardless of the stored preference — the
Mac build behaves as if the feature does not exist, without needing its own
code path.

**2. `.deviceOwnerAuthentication`, never `...WithBiometrics`.** The OS itself
offers the device passcode when Face ID/Touch ID fails or isn't enrolled, so
the app never has to design a "biometrics failed, now what" branch — Apple's
own recommended policy for exactly this reason. The one case the OS cannot
rescue is a device with **no passcode at all**: every evaluation then throws
`.unavailable` with nothing to fall back to. `AppLock.continueWithoutLock()`
is the app's own escape hatch for that single case, surfaced only from the
lock screen's `.failed(.unavailable)` branch — it turns the preference off
and unlocks, so the user is never truly locked out of their own data.

**3. Off by default.** `AppLock`'s `UserDefaults` key
(`"lock.biometricEnabled"`) is read with `defaults.bool(forKey:)`; an absent
key reads `false`, so no explicit registration is needed and a fresh install
or an update never surprises the user with a lock screen they never opted
into.

**4. `UserDefaults`, not Keychain.** The client's first use of
`UserDefaults` — for exactly one `Bool`. `docs/engineering.md`
restricts *financial* data from `UserDefaults`; a plain on/off preference is
not that, so this is a narrow, deliberate exception rather than a crack in
the rule. An attacker with physical access to the device could flip the key
directly (there is no Keychain-backed hardening in this repo). Accepted as
YAGNI for a personal, single-user app — see "Alternatives considered" below.

**5. Privacy cover, shipped unconditionally.** `LockOverlayModifier` shows
`PrivacyCoverView` — a deliberately content-free screen, just the wordmark on
the background color — whenever `scenePhase != .active`, **independent of
whether biometric lock is enabled at all**. This is the direct fix for
`data-safety.md`'s app-switcher-snapshot note, and it costs nothing extra:
the `scenePhase` observation and the root `ZStack` already had to exist for
the lock screen itself. Only the *require-authentication-to-return* half of
the feature is gated by the toggle; every user gets the snapshot protection
regardless.

**6. Lock on `.background` only, never on `.inactive`, no auto-retry.**
`.inactive` is deliberately a no-op in `AppLock.handleScenePhase(_:)` — the
system authentication prompt itself drives the app to `.inactive` while it's
on screen, so treating that transition as "went to background" would fight
the very prompt `authenticate()` just raised. A `.failed` state does not
auto-retry on the next `.active` — only `.locked` does — so a cancelled
prompt does not loop back at the user the instant they return to the app;
retrying is `authenticate()`, called from a button tap.

## What does not change

- The four-tab shell and its order (ADR 0009) — Impostazioni gains a third
  entry, nothing is restructured.
- `TraccioApp`'s `TabView` stays mounted, unconditionally, under the lock
  overlay (a `ZStack`, not a state-switched root view): every tab's own
  `.task`/`.onChange(of: scenePhase)` keeps running underneath, notably
  `AccountsView`'s post-bank-re-auth refresh
  (`AccountsView.swift:14,24`) — a lock/unlock cycle never discards tab or
  scroll state and never re-runs a tab's initial load.
- `docs/engineering.md`'s "logic lives in `TraccioCore`" is a rule for
  *business* logic; `AppLock` is platform/lifecycle wiring, the same category
  `DataFreshness` already occupies in `App/Sources/`, not `TraccioCore`.
- No new design tokens. `LockScreenView`/`PrivacyCoverView` compose only
  `Palette`/`Typography`/`PillButton`/`Banner`, already in
  `DesignSystem/`. Light-only, like every other screen — dark mode remains a
  separate, not-yet-started M3 item.
- No canvas artboard, same posture ADR 0009 already took for the
  Impostazioni tab itself: simple enough to compose from existing tokens.

## Consequences

- Every bank-reauthorization round trip through the system browser (Conti)
  now also costs an unlock when the feature is on, since leaving the app for
  the browser backgrounds it.
- `UserDefaults` now has exactly one key in this client; any future
  preference should ask explicitly whether it's "a `Bool` toggle" (fine) or
  something closer to financial data (not fine) before reusing this
  precedent.
- No CI can ever exercise the real prompt, the real passcode fallback, or
  the real app-switcher snapshot — `AppLockTests` covers the state machine
  exhaustively against `FakeBiometricAuthenticator`, but a manual device
  checklist is part of this slice's definition of done (`tasks/done.md`).
- `docs/design/canvas/` gains no artboard for this screen.

## Alternatives considered

- **A separate "locked" root view that swaps out the `TabView`.** Rejected:
  discards tab and scroll state and re-runs every tab's `.task` on every
  unlock — a `ZStack` overlay keeps everything mounted underneath for free.
- **`.deviceOwnerAuthenticationWithBiometrics` plus a hand-built passcode
  fallback.** Rejected: reinvents a system sheet the OS already provides for
  free via `.deviceOwnerAuthentication`, and introduces exactly the dead-end
  branch ("biometrics failed, now what") the chosen policy avoids by
  construction.
- **Keychain-backed preference instead of `UserDefaults`.** Rejected as
  premature hardening: this is a personal, single-user app where the
  realistic threat model is "someone picks up my unlocked phone," which the
  lock itself already addresses; a determined attacker with a jailbroken
  device and file-system access has bigger problems to exploit than one
  `UserDefaults` key. Revisit if this client ever has more than one user.
- **Auto-retry authentication on every return to `.active`, even after a
  cancel.** Rejected: turns a single cancelled prompt into a loop the user
  cannot escape without force-quitting the app.

## Revisit when

- A paid Apple Developer membership and a real macOS distribution path make
  the Mac build a shipped target, not a local dev convenience — the iOS-only
  scoping should be revisited then, not before.
- A grace period after the bank-re-auth browser round trip is wanted (skip
  the lock screen if the backgrounding was for Traccio's own system-browser
  flow and the return happens within a few seconds).
- Dark mode lands (M3 item 6) — `LockScreenView`/`PrivacyCoverView` need a
  `ColorScheme`-aware pass like every other screen at that point.
