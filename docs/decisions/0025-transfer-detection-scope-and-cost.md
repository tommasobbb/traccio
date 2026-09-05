# 0025 — Transfer detection: bound its scope and its cost

Status: accepted
Date: 2026-09-05

## Context

`GET /transfers/suggestions` became the app's worst-behaving endpoint in real
daily use. Tapping it on the phone would spin forever, and from then on every
other screen stopped loading too. Three things compounded:

1. **The detector is O(n²) in pure Python.** `detect_transfers`
   (`services/transfers.py`) scanned `combinations(candidates, 2)` — every
   unordered pair — and applied the `window_days` day-gap check *inside* the
   loop, so the window pruned results, not work. At ~530 real transactions
   that is ~140k iterations (fine); it grows quadratically and without bound
   as history accumulates.

2. **It ran over all of history.** The route called `list_all_transactions`,
   which is deliberately unpaginated. ADR 0024's `tracking_start_date` floor
   is injected only into `GET /transactions` and `GET /dashboard/summary`, so
   detection kept scanning exactly the partial-coverage pre-cutoff months the
   user configured the app to hide — months where pairing is unreliable
   anyway, since only whichever account connected first has data there.

3. **A single-worker backend has one GIL.** Every route handler is a plain
   `def` run in the AnyIO threadpool (`db/session.py` chose sync SQLAlchemy on
   purpose — single-user service). A CPU-bound pure-Python loop holds the GIL
   for its whole duration, starving every other in-flight request in that one
   uvicorn process on Fly `shared-cpu-1x`. That is why the freeze was
   app-wide, not confined to one screen.

The client amplified all of this: an unbounded per-leg fan-out (below), a
`URLSession` with `URLSessionConfiguration`'s 7-day resource-timeout default
so nothing ever gave up, and the endpoint fired on every Movimenti load. The
fan-out and the timeout are addressed here; splitting the Movimenti load is a
separate client change tracked in `tasks/backlog.md`.

## Decision

**1. Detection runs from `tracking_start_date` forward.**
`list_all_transactions` gains an optional keyword `since: date | None`; when
set it applies the same `_tracking_floor` bound `list_transactions` already
uses. `transfer_suggestions` depends on `api/deps.current_tracking_start` (the
one place the floor is read) and passes it as `since`. Rule application — the
other caller of `list_all_transactions` — passes nothing: a rule categorizes
every row regardless of the display floor, so its scope is unchanged.

**2. The pure detector uses a forward date window instead of an every-pair
scan.** Candidates are sorted by effective date; each is compared only with
the ones after it, and the inner scan `break`s as soon as the day gap exceeds
`window_days`. Cost drops from O(n²) to O(n·k), k = candidates within one
window. The set of pairs *considered* is identical to before — the change
only avoids building the pairs the old code would have discarded one line
later. All existing detection tests pass unchanged.

**3. The greedy assignment is given a total order.** The ranking key was
`(amount_delta, day_gap, kind_rank)`; a tie left the pick dependent on the
order pairs happened to be discovered in, which the date sort in (2) would
otherwise have changed. Two more key components — the outgoing then incoming
transaction id — make the result deterministic and independent of input
order. New test: `test_tie_break_is_deterministic_across_input_orders`.

**4. Each suggestion embeds both legs.**
`TransferSuggestionResponse` gains `outgoing` / `incoming`, the full
`TransactionResponse` projection `GET /transactions` already returns. The
router has every leg in memory (detection's own input pool) and resolves
event membership for the leg ids in one batched query. This kills the
client's `1 + 2N` fan-out — the previous client fetched every leg with a
separate `GET /transactions/{id}` in an unbounded task group, so 50
suggestions meant 100 concurrent requests against the same small pool.

**5. The client's default `URLSession` has explicit timeouts.**
`APIClient.defaultSession` (used whenever a caller injects no session — every
production path does) sets `timeoutIntervalForRequest = 30` (an idle
timeout, so a slow-but-progressing sync is unaffected) and
`timeoutIntervalForResource = 120` (a hard ceiling, generous enough for a
first years-of-history sync). Without this a wedged backend hung the screen
on the 7-day default. Tests inject their own stub session and are unaffected.

**6. The app engine's connection pool is configurable.**
`create_engine` in `db/session.py` now takes `pool_size` / `max_overflow` /
`pool_pre_ping` from `Settings` (`db_pool_size=5`, `db_max_overflow=10`,
`db_pool_pre_ping=True` — SQLAlchemy's own defaults, plus pre-ping). This does
not fix the freeze; it means a small managed Postgres can be given a smaller
pool without a code change, and a connection dropped while idle is replaced on
checkout rather than surfacing as a request error. The SQLite pool the tests
build is untouched.

## Consequences

- `list_all_transactions(session, user_id, *, since=None)` — new keyword,
  default preserves every existing caller.
- `detect_transfers` is behaviour-preserving except for tie resolution, which
  is now deterministic where it previously depended on input order.
- `/transfers/suggestions` no longer surfaces pairs from before the tracking
  start. This is consistent with that setting's intent; a user who wants to
  link an old pair still can via the explicit pick-two flow, which does a
  by-id lookup and is not floored (ADR 0024 §5).
- New settings `TRACCIO_DB_POOL_SIZE` / `TRACCIO_DB_MAX_OVERFLOW` /
  `TRACCIO_DB_POOL_PRE_PING`, documented in `.env.example`.
- `TransferSuggestionResponse` gains required `outgoing` / `incoming`
  objects — a wire change, so `docs/api/openapi.json` is regenerated and the
  Swift `TransferSuggestionResponse` model + its decode tests follow.
  `TraccioCore.pairSuggestions` loses its transaction-pool parameter (the
  legs are on the suggestion now) and can no longer drop a half-resolved
  pair, so `TransfersViewModel.load()` is a single request.
- `docs/domain.md` §Transfer is unaffected — the matching rules are the same.

## Alternatives considered

- **Move detection off the event-loop worker (a process pool / a background
  precompute).** Real fix for the GIL contention, but a new moving part for a
  single-user app. The O(n·k) window makes the synchronous cost small enough
  that this is not needed now; revisit if history grows past tens of
  thousands of rows.
- **Cache the suggestions and recompute on sync.** Same verdict — worth it
  only once the synchronous cost is actually a problem again.
- **Also floor `list_all_transactions` for rule application.** Rejected:
  rules must apply to every transaction, not just the visible window.

## Revisit when

- Transaction count reaches five figures — then precompute-on-sync or an
  out-of-process detector earns its keep.
- A second per-user setting lands and ADR 0024's `/settings` shape grows —
  the `since` plumbing here rides on `current_tracking_start` and needs no
  change.
