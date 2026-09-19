# 0014 — A shared bearer token, not real auth, gates the deployed backend

Status: accepted
Date: 2026-08-25

## Context

`api/deps.py::current_user_id()` has always resolved to a fixed
`Settings.dev_user_id` — real per-user authentication is explicitly blocked
on the M4 decision (`tasks/ROADMAP.md`), since Traccio is built for one user
and multi-user auth brings a legal-entity and GDPR surface that M4 alone
gets to open. That is a deliberate, documented gap on localhost.

It stops being a *localhost* gap once item 7 of the iPhone-trial roadmap
(`tasks/backlog.md`) puts the backend on a small always-on VPS so the client
can reach it from a real device. At that point every endpoint — accounts,
transactions, dashboard totals, the encrypted-at-rest bank connections
themselves — is reachable by anyone who finds the domain, with nothing in
between. This was surfaced during planning for that roadmap item, not asked
for directly, and needed closing before the deploy work could start.

## Decision

**A single shared bearer token, read from `Settings.api_token`
(`TRACCIO_API_TOKEN`), gates every request except `GET /health` and
`GET /connections/callback`.** Not real authentication — a lock on the front
door, sized to match the actual threat model (a personal, single-user app
whose only client is the owner's own phone), not a preview of what M4's real
auth will look like.

- `api/deps.py::require_api_token` compares the request's `Authorization:
  Bearer <token>` header against `Settings.api_token` with
  `secrets.compare_digest`, so response timing can't be used to guess the
  token a character at a time. `None` by default (unset in `.env.example`):
  the app keeps booting with no `.env`, and the whole existing test suite —
  which never sets `TRACCIO_API_TOKEN` — keeps running unauthenticated, as
  it always has.
- Wired once, on a parent `APIRouter` in `api/main.py`'s `create_app()`,
  rather than per endpoint: every resource router (`accounts`,
  `connections`, `transactions`, `transfers`, `advances`, `events`,
  `categories`, `rules`, `dashboard`) is included into a `protected`
  `APIRouter` and that one gets `dependencies=[Depends(require_api_token)]`.
  One gate, not nine repeated declarations.
- **Two exceptions, both structural, not configuration:**
  - `GET /health` has nothing to protect and needs to answer a monitoring
    probe that carries no token.
  - `GET /connections/callback` is called by the bank's SCA redirect
    landing in the system browser — it cannot carry a bearer header, full
    stop. It was already protected by its own unpredictable `state` value
    (`docs/openbanking.md`'s consent flow), which this decision leaves
    unchanged. `routers/connections.py` was split into two `APIRouter`
    instances (`router` and `callback_router`) so the callback can be
    included into `main.py` without the parent router's dependency, instead
    of trying to carve one route out of a dependency already applied to its
    router.
- Boot logs `auth.disabled` (identifier only, no secret) when `api_token` is
  unset, so a real deployment that forgot to set it is visible in the logs
  rather than silently open.

## Consequences

- The client needs to send the token on every call once a deployment sets
  it — a follow-up client-side task (base URL + token configuration,
  Keychain storage), tracked separately in `tasks/backlog.md` rather than
  bundled here, since this ADR is backend-only.
- `docs/api/openapi.json` does not yet declare a security scheme for this
  header — `make openapi` regeneration for that is cosmetic (FastAPI/Swagger
  UI convenience), not a functional gap, and is left for whenever the
  OpenAPI schema next needs a real reason to regenerate.
- Every request except the two exceptions above now costs one constant-time
  string comparison. Negligible next to a database round trip.

## Alternatives considered

- **mTLS (client certificate).** Rejected for now: real protection, but
  requires Keychain identity management and a custom `URLSession` delegate
  on the client for one extra increment of security a personal app with one
  known caller doesn't need yet. Revisit if the trial ever has more than one
  client.
- **VPN/Tailscale in front of the VPS instead of a token.** Rejected: it
  contradicts the already-locked hosting decision ("small always-on VPS, not
  Tailscale" — `tasks/backlog.md`), and the consent callback must stay
  reachable by the bank's own redirect regardless, so the backend can't be
  fully VPN-walled either way.
- **No auth for the trial.** Rejected: real bank data for three live
  accounts, reachable by anyone who finds the domain, is not an acceptable
  risk to accept just to save half a day of work.

## Revisit when

- M4 is reached and real per-user auth is in scope — this token is replaced
  wholesale, not extended; `require_api_token` and `current_user_id` both
  disappear together rather than growing a multi-user shim.
- A second client (beyond the owner's own phone) ever needs to call the
  backend — that's the trigger to reconsider mTLS.

## 2026-08-25 revision: client wiring

The follow-up flagged in Consequences above. `APIClient+Dev.swift`'s
hardcoded `http://localhost:8000` (a force-unwrapped literal —
`docs/engineering.md` forbids `!` outside test scaffolding, which this
already wasn't) is replaced by `TraccioCore.ServerConfigurationStore`: the
base URL in `UserDefaults` (not financial data), the token in the Keychain
via a new `APITokenStoring` seam (`KeychainAPITokenStore` in production, an
in-memory fake in tests — the real Keychain adapter is exercised only by a
one-off manual script, not the automated suite, since Keychain access from a
sandboxed `swift test` process isn't reliable to assert on).

`APIClient` gained an `apiToken` parameter, attached as `Authorization:
Bearer` on every request when set; `APIError` gained `.unauthorized`,
mapped from a `401` response and split out from the generic `badStatus` so
the client can say "check your server token" specifically. Every
`= APIClient.devDefault` default-parameter call site (13 of them, across
every view model) was renamed to `= APIClient.current` — `devDefault` had
become a misnomer once the value stopped being a fixed dev constant.

A new "Server" section in Impostazioni (`ServerSettingsViewModel`) edits and
verifies both fields before ever persisting them: "Verifica e salva" builds
an *ad-hoc* client from whatever is currently typed (never
`APIClient.current`, which would only reflect what was already saved), calls
`GET /health` then an authenticated endpoint, and only calls
`ServerConfigurationStore.save` once both succeed — so a saved configuration
has always already been proven to work, and the three failure shapes (bad
URL, unreachable server, wrong token) get distinct Italian copy rather than
one generic error.

**One deliberate, documented limitation**: `APIClient.current` is a computed
property, re-evaluated on every call — but every tab's view model is
constructed once, at app launch (`TabView` builds all four tabs up front).
Changing the server configuration takes effect for any *newly created*
screen, but an already-running tab keeps using the client it was built
with until the app is relaunched. Rearchitecting client injection so every
live screen picks up a change instantly (an environment-injected client,
observed and swapped app-wide) was judged out of scope for this slice —
restart-to-apply is a standard, well-understood pattern for base-URL
settings in mobile apps, and the alternative is a much larger change to
touch for a value that, once set for a personal single-user deployment,
rarely changes again.

**Verified**: `xcodebuild` macOS build clean, zero warnings. `swift test`
(TraccioCore, 232, up from 225 — 3 new `APIClient` header/401 cases, 4 new
`ServerConfigurationStore` cases) and `make test-app` (127, up from 121 — 6
new `ServerSettingsViewModel` cases against `FakeAPIClient`) green. The real
`KeychainAPITokenStore` logic verified by a one-off manual script exercising
add/update/delete against the real Keychain on this machine (all
`errSecSuccess`), matching `docs/decisions/0013-biometric-lock.md`'s
precedent of verifying a system-API adapter by hand alongside the automated
seam tests rather than only in them.
