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

**3. Incremental windowing only after the first sync.** A connection's first
sync (`last_synced_at is None`) still uses the greedy
`initial_history_days` window — the post-authorization window a bank serves
full history for does not come back, so there is no second chance at it.
Every later sync requests only since `last_synced_at` minus the new
`TRACCIO_SYNC_OVERLAP_DAYS` (default 7), free to be generous about because
`upsert_transaction` is idempotent on stable identity.

**4. The background fetch budget is counted in `SyncRun` rows, not raw
provider HTTP calls.** `docs/openbanking.md`'s "~4 background fetches per
day" is read as "~4 sync *attempts* per day per connection" — one run
already makes several provider calls internally (list accounts, fetch each
account's transactions, follow pagination), and Traccio has no visibility
into the provider's own internal call accounting anyway. Every attempt is
recorded, including a skip (`SyncRunOutcome.SKIPPED_*`), which is what makes
the budget verifiable from the data rather than trusted on faith — the same
motivation behind adding the `SyncRun` entity `docs/domain.md` had described
but never modeled.

**5. The sync decision is derived fresh every tick, never stored.**
`domain/sync_schedule.py::sync_decision` is a pure function of
`(consent_state, runs_last_24h, last_synced_at, now, budget_per_day,
min_interval_hours)` — sibling to `domain/consent.py::consent_state` (ADR
0006) and for the same reason: a stored "next due at" timestamp needs a
background job to stay true and is wrong between runs, while deriving it from
the clock and the `SyncRun` history already on record is correct the instant
it is computed, with nothing extra to keep in sync.

**6. The scheduler assumes exactly one uvicorn worker process.** With more
than one process, each would run its own independent loop and the
per-connection budget would be counted, and burned, separately by each one —
`Settings.background_sync_budget_per_day=4` would in practice become `4 ×
worker_count`. Not solved here: a database-level lock (e.g. an advisory lock
per connection, or a single "scheduler owner" row) is real work that a
single-user personal deployment does not need yet (YAGNI) — `make run`'s
`uvicorn --reload` is already single-process, and M3's hosting decision
(`tasks/backlog.md`: Tailscale vs. a small VPS vs. LAN) has not landed on
anything that would run more than one worker either. Revisit if it does.

**7. `TRACCIO_BACKGROUND_SYNC_ENABLED` defaults to `false`.** `backend/CLAUDE.md`
requires the app to boot with no `.env` present; a background loop that calls
a real bank the moment the server starts, with no explicit opt-in, is exactly
the surprise that default exists to prevent. Turning it on is a deliberate
step the person running the backend takes, not a side effect of upgrading.

## Revisit when

- A second background-orchestration module shows up needing the same widened
  `services/` imports (a hypothetical future scheduler for something other
  than sync) — confirms the column change earns its place rather than
  existing for one caller.
- The single-process assumption (decision 6) stops holding, once a hosting
  decision actually runs more than one worker.
- PSU-present headers (`SyncContext(psu_present=...)` is still discarded by
  the adapter) and wiring `POST /rules/apply` into the sync pipeline as a
  detection step (ADR 0005) are the two backlog items this scheduler was the
  gate for that remain open — both still need their own slice.
