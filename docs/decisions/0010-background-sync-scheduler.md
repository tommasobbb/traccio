# 0010 — Background sync scheduler

Status: accepted
Date: 2026-08-24

## Context

M3's roadmap "done when" is explicit: sync that does not need babysitting.
Until now every sync is manual — a per-connection button on the Conti screen
— and every sync (manual or otherwise) re-fetches `TRACCIO_INITIAL_HISTORY_DAYS`
(~730 days) of history regardless of how recently it last ran. This is also
the gate three already-filed backlog items were waiting on: PSU-present
headers (`SyncContext(psu_present=...)` is threaded to the adapter and then
discarded), incremental windowing (explicitly deferred to "the background
scheduler" when idempotent dedup landed), and wiring `POST /rules/apply` into
the sync pipeline as a detection step (ADR 0005: "once background sync
scheduling (M3) exists").

`docs/domain.md` §Sync already describes a `Sync` entity — "records what was
attempted, when, and what failed" — that was never actually modeled. This
work builds it.

The hard constraint driving every decision below: many banks allow only ~4
background fetches per day per consent (`docs/openbanking.md`); exceeding it
gets the consent throttled. This is a product constraint, not a tuning
parameter — the scheduler must refuse to run rather than retry into a
throttle.

## Decisions

**1. `services/` is widened to import `db`, `providers`, and `core` — not
just `domain`.** Every service module until now (`advances.py`,
`categorization.py`, `transfers.py`) is pure, importing only `domain`, per
`docs/architecture.md`'s original table. Sync cannot be: it is inherently I/O
orchestration — decrypt a stored credential, call the bank adapter, write
rows — and both an HTTP-triggered sync and the scheduler need to run the
identical path, or the pipeline exists twice and drifts. The alternative
(keep `services/sync.py` pure, thread `~6` repository functions through its
signature as parameters) was rejected: it preserves the letter of the old
table at the cost of ceremony the code has not earned
(`.claude/rules/python.md`'s own YAGNI guidance). What still holds without
exception: `db/`, `providers/`, and `core/` never import `services/`, and
`services/` never imports `api/` — HTTP status codes and request/response
schemas stay in the router. `docs/architecture.md`'s layer table is updated
in the same change.

**2. The sync orchestration itself moved out of the router.**
`api/routers/connections.py::sync_connection`'s ~60-line body became
`services/sync.py::sync_connection`; the router is now a thin translator from
the service's typed exceptions (`ConnectionNotFoundError`,
`ConsentExpiredError`, `CredentialsUnavailableError`) to `HTTPException`s,
plus the PSU-present context and the commit. Distinct exception types, not one
type carrying a reason string (contrast `RuleError`/`AdvanceError`), because
each one maps to a *different* HTTP status — a single reason-code type would
just be re-parsed into a branch in the router anyway. The service does not
commit; like every `db/repositories.py` function, the caller owns the
transaction boundary, so both the router and the scheduler commit after a
successful call.

## Revisit when

A second background-orchestration module shows up needing the same widened
imports (a hypothetical future scheduler for something other than sync) —
confirms the column change earns its place rather than existing for one
caller.
