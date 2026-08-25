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
