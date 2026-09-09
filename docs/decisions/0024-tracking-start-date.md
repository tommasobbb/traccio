# 0024 — Tracking start date: a reversible per-user floor, not a delete

Status: accepted
Date: 2026-08-30

## Context

The synced connections were authorized at different times and each bank
serves a different depth of history (374 Revolut movements, 141 PayPal, 14
Isybank; ~2 years is the greedy `initial_history_days` default but most
banks return ~90 days). So the earliest months on the dashboard contain
data from only whichever accounts happened to be connected first — a
"spending" total for six months ago that is really just PayPal is
misleading, not informative. The user wants to start clean: count from the
first month every account has data, and not see the partial months at all.

Two things did not exist before this: any **per-user setting** (`UserRow`
held only `id` and `created_at`, there was no settings router), and any way
for the client to know an account's first-movement date.

## Decision

**1. A single per-user column, `users.tracking_start_date DATE NULL`.** Not a
`user_settings` table — there is exactly one setting, and a table earns its
keep only at the second. `NULL` — every existing user, and the default —
means "no floor, show everything". A `DATE`, not a `DATETIME`: the user
picks a whole-day boundary (conceptually a month), not an instant. Migration
`b8c9d0e1f2a3`, a plain nullable `ADD COLUMN`, no backfill.

**2. A reversible display filter, never a delete.** Raising or clearing the
date only changes which movements the dashboard and Movimenti *show*; every
row stays in the database. This is the whole reason it is a filter and not a
`DELETE`: the ~1h post-authorization window is the only chance at full bank
history, so a pre-cutoff delete would be unrecoverable. Move the date back,
the movements reappear.

**3. Applied in one place, injected as a dependency.** `list_transactions`
gains a `tracking_start` parameter; `_tracking_floor(date)` turns it into the
`coalesce(booked_at, value_date) >= <UTC midnight of that day>` bound (a
dateless row is excluded, the same way any `start`/`end` bound already
treats one). The value comes from `api/deps.current_tracking_start`, and
`GET /transactions` and `GET /dashboard/summary` are the only two routes
that depend on it — a route showing transactions cannot forget it because
there is one place it is read.

**4. The dashboard raises the floor into the requested period, before
anything is fetched or bucketed.** `_bucket_grid` and
`_average_daily_spending` work from the *requested* `period_start`; clamping
only the query would leave empty leading buckets and a wrong daily average.
So `dashboard_summary` computes `start = max(start, floor)` (and the same for
`compare_start` when comparing) once, and that clamped value drives both
`list_transactions_in_period` and `summarize`.

**5. Not applied to by-id reads.** An advance, event, or reimbursement
detail, and transfer detection, still see every row — an explicit link to an
old movement must keep working. The floor is a *list-and-dashboard* filter.
The greedy sync still fetches `initial_history_days` (the filter is
reversible, so there is no reason to fetch less).

**6. A suggestion endpoint, `GET /settings/tracking-start/suggestion`.**
`earliest_transaction_dates_by_account` returns `min(when)` per account;
`domain/tracking.suggest_tracking_start` (pure) folds those into the first
day of the earliest month every account covers — the latest-starting
account is the constraint, and if its first movement is on the 1st that
whole month is already covered (no need to skip it). The response also names
the `constraining_account_id` and lists every account's first-movement date
(accounts with none included, `earliest: null`), so the client can show the
user *why* the suggestion is where it is.

**7. `POST /settings` is mandatory-but-nullable.** The `tracking_start_date`
key must be present; `null` clears, an omitted key is a `422`. Same posture
as `POST /accounts/{id}/rename` (ADR 0017), and the Swift request model
needs the same hand-written `encode(to:)` to emit an explicit `null`.

## Consequences

- New: `users.tracking_start_date`, `domain/tracking.py`,
  `api/routers/settings.py` + `api/schemas/settings.py`,
  `get_tracking_start_date` / `set_tracking_start_date` (upserts the `users`
  row — a fresh test db has none) / `earliest_transaction_dates_by_account`
  in `db/repositories.py`, `current_tracking_start` in `api/deps.py`.
- Client: `TrackingStartResponse` / `SetTrackingStartRequest` /
  `TrackingStartSuggestionResponse` models (+ decode tests),
  `settings()` / `setTrackingStart(_:)` / `trackingStartSuggestion()` on the
  API client, a "Inizio tracciamento" screen in Impostazioni
  (`TrackingStartView` + `TrackingStartViewModel`). `DashboardViewModel`
  fetches the floor on `load()` and disables the ◀ period button when the
  previous period lies entirely before it. Movimenti's `.all` preset is
  relabelled "Dall'inizio" — it still stops at the floor server-side.
  *(2026-09-05 refinement)*: the ◀ button also falls back to the earliest
  movement date (`GET /settings/tracking-start/suggestion`'s
  `accounts[].earliest`, min) when no explicit floor is set, and a new ▶
  button disable stops paging into a period that has not begun —
  `CalendarPeriod.isEntirelyAfter(_:)`. The per-period `settings()` round
  trip moved to a `load()`-only path (`reloadSummary()` handles navigation).
- A dateless movement (no `booked_at`, no `value_date`) is hidden while a
  floor is set. This matches how every other date bound treats one; the user
  who wants to see them clears the date.
- `docs/domain.md`: §User (the setting) and §Dashboard (the floor).

## Alternatives considered

- **Delete pre-cutoff rows.** Rejected: unrecoverable — bank history cannot
  be re-fetched after the post-auth window.
- **A `user_settings` table.** Rejected for now: one setting, one column;
  revisit at the second.
- **Client-only (`UserDefaults`).** Rejected: ADR 0017's rule — a user
  preference lives on the backend, or it vanishes on reinstall and never
  syncs to a second device.
- **Apply the floor inside `list_transactions_in_period` too.** Rejected as
  redundant and worse: the dashboard must clamp `period_start` for the bucket
  grid regardless, so clamping once in the router and passing the result to
  both the query and `summarize` is the single source of truth.

## Revisit when

- A second per-user setting appears — then a `user_settings` table (or a
  JSON column) is worth it, and `/settings` grows a real shape.
- Per-account start dates are wanted (keep account A from June but account B
  from March) — this decision deliberately does one global floor.

## 2026-09-09 revision: the floor reaches the Anticipi list and its summary

ADR 0026's cross-advance receivables summary (`GET /advances`) shipped without
the floor — "chi ti deve" and "da ricevere" counted **every** advance the user
had ever created, including ones whose transaction predates the tracking start
and is therefore invisible on the dashboard and in Movimenti. That is exactly
the "misleading total from partial history" this ADR exists to prevent, so the
floor now applies there too.

- **Same "list-and-dashboard filter" category as §3**, not a new kind of
  thing. `GET /advances` gains `tracking_start: Depends(current_tracking_start)`
  — the fourth consumer of that single dependency, alongside `GET /transactions`,
  `GET /dashboard/summary`, and transfer detection.
- **Applied in Python, not SQL.** `list_advances` stays a plain user-scoped
  select (the dashboard also calls it, unfloored, as a by-id lookup map —
  see ADR 0026). The router loop in `api/routers/advances.py` already loads
  each advance's transaction to derive its state; a new pure predicate
  `domain/tracking.is_within_tracking(transaction, tracking_start)` — the
  single-transaction counterpart of `_tracking_floor`'s SQL bound
  (`coalesce(booked_at, value_date) >= UTC midnight`, a dateless row excluded)
  — gates the advance before it reaches `advance_states` /
  `participant_states_by_advance`, so the returned rows and the `summary`
  move together and cannot disagree.
- **§5 still holds.** `GET /advances/{id}` does not filter — an explicit link
  to an old movement keeps working, and the floored-out advance stays
  reachable by id. Raising or clearing the date is still fully reversible.
