# 0037 — The background sync budget counts fetches, not skips

Status: accepted
Date: 2026-09-19

## Context

`docs/openbanking.md`'s hard constraint is "~4 background fetches per day per
consent." ADR 0010 (decision 4) read this as "~4 sync *attempts*" and counted
every `SyncRun` row in the rolling 24h window toward that budget, including a
skip — the stated reasoning was that "a skip already means a decision was
evaluated for this connection in the window," so it should count the same as
an attempt that actually called the bank.

That reasoning has a hole `sync_decision`'s own three-gate order exposes: the
scheduler ticks once per `background_sync_interval_minutes` (60, by default)
and, for **every connection that isn't due**, writes a `SKIPPED_*` row
(`services/scheduler.py::run_due_syncs`) — not just for one that has already
used its four attempts. A connection with `background_sync_enabled` on and no
transactions yet due (freshly connected, or waiting out
`sync_min_interval_hours`) still gets a skip row once an hour. Four hours
after the scheduler starts, `runs_last_24h` for that connection is already 4
— purely from `SKIPPED_INTERVAL`/`SKIPPED_CONSENT` rows that called no
provider at all — and `sync_decision` returns `SKIPPED_BUDGET`. That tick
writes a *fifth* row into the same rolling window. So does the one after it.
The count never drops back below the budget on its own, because every tick
that observes the exhausted budget adds another row that keeps it exhausted:
a self-sustaining lockout, not a transient one. From the fourth hour after any
process start onward, the scheduler can only report `SKIPPED_BUDGET` for that
connection, forever, until the process restarts and the rolling window
eventually empties out again — which gives it another ~4 hours before the
same thing happens.

Found by reading `count_recent_sync_runs` alongside `run_due_syncs` while
debugging why production's background sync — genuinely enabled
(`TRACCIO_BACKGROUND_SYNC_ENABLED=true` since 2026-08-25,
`tasks/done.md`) — had synced nothing for the eight days its Fly.io machine
had been continuously up (`min_machines_running = 1`, `auto_stop_machines =
false`, so the process had not restarted since 2026-09-11).

## Decision

**The budget counts only the outcomes that actually reached the provider:**
`SyncRunOutcome.SUCCESS` and `SyncRunOutcome.PROVIDER_FAILED`. A new
`SyncRunOutcome.counts_toward_budget` property (`domain/enums.py`) names this
explicitly, and `db/repositories/sync_runs.py::count_recent_sync_runs` /
`oldest_recent_sync_run_started_at` both filter on it. Nothing else changes:

- Every attempt is still recorded, skips included — `SyncRun`'s purpose as an
  audit trail (ADR 0010 decision 4's first half, and `docs/domain.md` §Sync:
  "records what was attempted, when, and what failed") is unaffected. Only
  what counts *toward the budget* changes.
- `sync_decision`'s three gates, their order, and `services/scheduler.py`
  are untouched — the fix is entirely in what the count they read means.
- `docs/openbanking.md`'s constraint reads correctly again: "~4 background
  *fetches*" was always about calls to the bank, not about how many times the
  scheduler merely looked at a connection and decided not to call it.

## Consequences

- The scheduler can now sync a connection more than once per ~4 hours of
  process uptime — the actual intended behavior since ADR 0010, blocked in
  practice by this bug for any deployment whose process stays up longer than
  that (which is the normal case: `min_machines_running = 1` exists
  specifically so the scheduler keeps running).
- `sync_budget_remaining` (`GET /connections`) now reports a number that
  reflects real fetches left today, not one already zeroed out by the
  scheduler's own bookkeeping.
- Requires a production deploy to take effect — the fix lives entirely in
  `backend/`, no client change, no migration (no schema change; `SyncRunRow`
  is unchanged, only which rows a query counts).

## Alternatives considered

- **Lower the scheduler's tick frequency so fewer skip rows accumulate.**
  Rejected: this delays the deadlock, it doesn't fix it — the same
  self-sustaining lockout still occurs once enough ticks pass, just later.
- **Stop recording a `SyncRun` for a skip at all.** Rejected: it would fix
  the budget but throws away the audit trail ADR 0010 built `SyncRun` for in
  the first place — `tasks/backlog.md`'s open item on surfacing a failed
  background sync in the client depends on that history existing.
- **Widen the rolling window's decay instead of changing what it counts**
  (e.g. only count the most recent N rows regardless of outcome). Rejected:
  still counts non-fetches against a fetch budget, just with different
  arithmetic — the category error is what needed fixing, not the window size.

## Revisit when

- A future backlog item (`tasks/backlog.md`, "does not cover a failed
  background sync") builds a client surface over `SyncRun` history — it
  should distinguish a budget-counted run from a skip the same way this ADR
  now does, rather than re-deriving the distinction.
