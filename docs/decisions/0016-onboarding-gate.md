# 0016 — Gate the four-tab shell behind onboarding instead of fixing client injection app-wide

Status: accepted
Date: 2026-08-25

## Context

ADR 0014's client revision hardcoded a known limitation: `APIClient.current`
is a computed property that re-evaluates on every access, but every tab's
view model is constructed once, at app launch, when `TabView` builds all
four tabs up front. Saving a new server configuration in Impostazioni ▸
Server only takes effect for a screen created *after* the change — an
already-running tab keeps using the client it was built with until the app
is relaunched. That ADR judged rearchitecting client injection (an
environment-injected, observed, swappable client) out of scope for that
slice.

This stopped being a cosmetic gap once daily real-device use started
(2026-08-25, the first real-iPhone install): a fresh install has *no* saved
configuration at all, `ServerConfigurationStore.load()` falls back to
`http://localhost:8000` (unreachable from a phone on cellular/Wi-Fi), and
the four-tab shell would render immediately with every tab failing. Nothing
in the UI would explain why, or point at Impostazioni ▸ Server as the fix —
the exact "four tabs that all fail before the user has had a chance to
configure anything" scenario the M3 polish backlog named directly.

## Decision

**`TraccioApp` does not construct `TabView` at all until the server is
known to work.** A new `ServerConfigurationStoring.isConfigured: Bool`
(backed by a dedicated `UserDefaults` flag, `server.configured`, set only
inside `save()`) answers "has a configuration ever been verified and saved"
— distinct from `load()`, which always returns *some* configuration, since
the zero-config default is itself a valid value for local development, not
a sentinel for "unset". `TraccioApp` reads this once at launch into
`@State private var isConfigured` and switches its `WindowGroup` body:
`OnboardingView` while `false`, the existing four-tab `TabView` once `true`.

`OnboardingView` reuses `ServerSettingsViewModel` exactly as Impostazioni ▸
Server does — same verify-before-persist behavior, same error copy — rather
than a parallel onboarding-specific flow. It calls `onComplete` (which flips
`isConfigured`) the moment `verifyAndSave()` reaches `.success`.

**This is also how the ADR 0014 limitation gets sidestepped for the
first-run case, without the app-wide client-injection rearchitecture that
ADR 0014 deferred.** `TabView` and every view model inside it are
constructed for the first time only *after* a successful save, so their
`= APIClient.current` default parameters read the just-saved configuration
on their very first construction — there is no "already-running tab with a
stale client" to fix, because no tab has run yet. A configuration *change*
after onboarding (an already-configured install pointing itself somewhere
else) still needs a relaunch, exactly as ADR 0014 already documented — this
decision narrows that gap for the one case that actually blocked real
device use, not the general one.

## Consequences

- A fresh install's first screen is `OnboardingView`, not a tab that
  immediately fails — closes the "onboarding minimo al primo avvio" item
  from the M3 polish backlog.
- `ServerConfigurationStoring` gained a required member
  (`isConfigured: Bool`); every conformer needed updating —
  `ServerConfigurationStore` (the real `UserDefaults`-backed
  implementation) and both test fakes
  (`ServerSettingsViewModelTests.FakeServerConfigurationStore`,
  `ServerConfigurationTests`'s in-memory store).
- The general "restart to apply a changed configuration" limitation from
  ADR 0014 is unchanged and still applies to Impostazioni ▸ Server after
  first run.

## Alternatives considered

- **Fix client injection app-wide** (environment-injected, observed,
  swappable `APIClient`, live-propagating to every already-built screen).
  The complete fix, but a much larger change than this gap warranted —
  ADR 0014 already declined it once, and nothing here changed that
  calculus; onboarding only needed the *first-run* case solved.
- **Detect "unconfigured" from `load()`'s default value directly** (e.g.,
  "is the base URL still `http://localhost:8000`?") instead of a dedicated
  flag. Rejected: indistinguishable from a real user deliberately pointing
  at a local `make run` backend, which is the zero-config default's whole
  point (ADR 0014). A dedicated `isConfigured` flag is unambiguous.

## Revisit when

- The general restart-to-apply limitation becomes annoying enough in
  practice to justify the app-wide client-injection rearchitecture —
  `OnboardingView`'s save path would keep working unchanged either way.
