# 0006 — Consent lifecycle: derived expiry state, re-auth in place

Status: accepted
Date: 2026-08-21

## Context

M1 was marked met on 2026-08-20 against real Revolut/Isybank/PayPal data, but
`tasks/backlog.md` left "Consent lifecycle: expiry tracking, re-auth flow" open.
`ConnectionStatus.EXPIRED` existed and was documented ("consent lifetime
elapsed; the user must re-authorize from scratch"), but nothing in the codebase
ever wrote it — `activate_connection` was the only writer of `status`, and it
only ever set `ACTIVE`. A connection whose 180-day consent had lapsed still
read `active` forever: `GET /connections` reported it healthy, and
`POST /connections/{id}/sync` called the provider and surfaced whatever opaque
error it returned. `docs/openbanking.md` already named this exact risk: "an
expired connection silently stops producing data."

There was also no re-authorization path at all — only `POST /connections`,
which always creates a new pending connection. A lapsed consent's only
recourse was a second connection row for the same bank, orphaning the first.

This ADR settles how expiry is represented and how re-authorization attaches
to an existing connection, before either is exposed to a client.

## Decision

**1. The actual consent state is derived, never stored.**

`domain/consent.py::consent_state(connection, *, now, warning_window_days)`
re-reads a stored `ConnectionStatus.ACTIVE` against `expires_at` and the
current time on every read: past expiry it is `ConsentState.EXPIRED`, inside
`Settings.consent_warning_window_days` (default 14) it is
`ConsentState.EXPIRING_SOON`, otherwise it stays `ConsentState.ACTIVE`. An
active connection with no recorded `expires_at` stays `ACTIVE` — no expiry
known is not the same as expired. `PENDING`/`REVOKED`/`ERROR`/a
provider-reported `EXPIRED` pass through unchanged; only the provider tells us
those, so no clock reading overrides them.

This mirrors ADR 0004's `Advance.settled`: a stored expiry flag needs a
background job to keep it true and is wrong the instant reality moves past it
without that job running. Traccio has no background scheduler yet (M3).
Deriving `consent_state` from `now` on every read is correct immediately, with
no scheduler required — the same reason `settled` was derived instead of
transitioned.

`ConnectionStatus.EXPIRED` keeps its existing meaning as a *provider-reported*
terminal state (should Enable Banking ever report one directly) and stays
available for a future revocation path. It is simply not what answers "is this
consent still good right now" — `ConsentState` is.

**2. Re-authorization reuses the same `Connection` row.**

`POST /connections/{id}/reauthorize` re-arms the existing connection with a
freshly issued anti-CSRF `state` (`db/repositories.py::set_connection_auth_state`)
and starts a new SCA authorization for the same institution and country.
Completing it through the existing `GET /connections/callback` activates that
same row — `find_pending_connection_id` already matches on `auth_state` alone,
not on `status`, so the callback needed no change to find a re-authorizing
connection regardless of its current status.

The alternative — always creating a fresh `Connection` on re-auth, mirroring
`POST /connections` — was rejected: it orphans the original row (and its
accounts, still pointing at the dead connection) and forces a second
onboarding UI ("is this the same bank as before?") for what is, functionally,
renewing the same link. Enable Banking documents the per-account
`identification_hash` as stable across sessions *and re-authorizations*
(`docs/openbanking.md`) — precisely what makes reusing the row safe: a re-sync
after re-auth updates the same account rows in place rather than duplicating,
so transaction history survives untouched.

**3. `country` is now persisted on `Connection`.**

`POST /connections` accepted `institution` + `country` from the start but only
persisted `institution` (as `institution_name`); `country` was silently
dropped. Re-authorization needs it again to call `start_authorization`.
Existing rows get `NULL` (nullable column, additive migration); a connection
with no stored country cannot be re-authorized in place
(`409 country_unknown`) and falls back to a fresh `POST /connections` instead
of guessing a value that changes which bank endpoint gets called.

**4. A sync on a derived-expired consent is refused before the provider is
called.**

`POST /connections/{id}/sync` checks `consent_state` first and returns
`409 consent_expired` rather than letting a `ProviderError` from a dead
session bubble up as an opaque `502`. The distinction matters to the client:
`502` means "something went wrong, maybe retry"; `409 consent_expired` means
"nothing to retry, re-authorize."

## Consequences

- No scheduler or stored expiry flag is needed for expiry to be correct;
  `consent_state` is a pure function of `(status, expires_at, now,
  warning_window_days)`, recomputed on every `GET /connections`.
- `GET /connections` now returns `consent_state` and `days_until_expiry`
  alongside the raw `status`/`expires_at`; the client renders `consent_state`
  and never re-derives it, per the "backend owns every derived value"
  invariant.
- A connection created before this slice (`country IS NULL`) degrades
  gracefully: it still syncs and still reports its derived `consent_state`
  correctly, it just cannot use the in-place re-auth path until its next full
  `POST /connections`.
- The SwiftUI surface (an expiry banner, a re-auth button) is deferred to the
  M3 client catch-up, same as every other M2/M1-tail backend slice.

## Alternatives considered

- **A background job that flips `status` to `EXPIRED` on a schedule.**
  Rejected: requires the M3 scheduler that does not exist yet, and is wrong
  between runs regardless — see Decision 1.
- **Always create a new `Connection` on re-auth.** Rejected — see Decision 2.
- **Guess `country` from `institution_name` or a hardcoded default on
  re-auth.** Rejected: country is part of the ASPSP lookup key
  (`docs/openbanking.md` — `aspsp` is `name` + `country`), and a wrong guess
  calls the wrong bank endpoint outright rather than failing loudly.

## Revisit when

- The M3 background scheduler lands: a proactive expiry-warning push (rather
  than the client polling `GET /connections` and reading `consent_state`) can
  be layered on without changing this ADR's derivation.
- PSU-present headers are implemented (separate backlog item, not this
  slice): `required_psu_headers` on a bank's ASPSP details may end up living
  alongside `country` on `Connection`, since both are per-institution facts
  learned at authorization time.
