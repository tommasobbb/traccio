# 0007 — Dashboard aggregation: effective_amount only, per-currency, no breakdown

Status: accepted
Date: 2026-08-21

## Context

`tasks/ROADMAP.md`'s M2 "done when" is: "I can tag a real advance from a real
trip and watch the dashboard show my actual share rather than the full
amount." Every M2 building block this depends on has shipped — role model and
`effective_amount` (2026-08-20), transfer detection and confirm/reject,
advances, reimbursements, events, categories, the rules engine — but nothing
aggregates them into "how much did I actually spend and receive." `GET
/transactions` exposes `effective_amount` per row and `event_total` sums it
across one event's members; neither answers the whole-period question a
dashboard needs, and `tasks/backlog.md` has carried "Dashboard: spending and
income from effective_amount only" as the last open M2 item since M1 closed.

The read-side logic to resolve an advance transaction's signed spending share
already existed twice, near-verbatim, in `api/routers/events.py` and
`api/routers/transactions.py`. This slice is the third caller, so that
resolution was extracted first into `services/advances.py::spending_shares`
(pure, imports only `domain`) rather than copied a third time.

This ADR settles what the dashboard aggregates, how currencies are handled,
and what "period" means, before exposing any of it to a client.

## Decision

**1. The summary is `effective_amount` only, never raw `amount`.**

`domain/dashboard.py::summarize` sums each transaction's
`effective_amount` (advance transactions via the caller-resolved
`advance_shares`, exactly like `event_total`) and never touches `Transaction.money`
directly. This is not a new rule — it is `docs/architecture.md`'s existing
invariant that the two are never mixed — but the dashboard is the first place
that invariant becomes user-visible as a headline number, so it is worth
naming here: a transfer between the user's own accounts must not inflate
spending, an advance must show only the user's declared share, and a
reimbursement must not read as income.

**2. One summary per currency; never summed across currencies.**

Traccio does no FX conversion (`docs/domain.md`). `event_total` treats a
mixed-currency event as an error, because an event is supposed to have one
total. A dashboard period has no such expectation — spending money in two
currencies during the same period is normal, not a mistake — so `summarize`
groups by currency and returns one `CurrencySummary` per currency present,
sorted by code for a deterministic response, rather than raising.

**3. `spending`/`income` are positive magnitudes; `net` is the one signed
figure.**

Same convention as `domain/advances.py` (`receivable`, `outstanding`): a
magnitude reads naturally on a dashboard ("€340 spent"), and the single signed
figure (`net = income - spending`) is what a headline "up or down" number
should be. A zero `effective_amount` (a transfer, a reimbursement, a rejected
movement) contributes to neither `spending` nor `income`, but is still
counted in `transaction_count` — it was considered, it just carried no
weight.

**4. The period is measured on `coalesce(booked_at, value_date)`, half-open
`[start, end)`.**

`db/repositories.py::list_transactions_in_period` reuses the exact expression
`list_transactions`/`list_all_transactions` already order by, rather than
introducing a second notion of "when" a transaction happened. The bounds are
half-open so consecutive periods (this month, then next month) never overlap
or double-count a row landing exactly on the boundary. A row with both dates
`NULL` is excluded by any bound on that side but included when the
corresponding bound is `None` — there is nothing to compare, so it can only be
judged "in range" when nothing constrains that range. Pending transactions
are included: a pending spend is money already committed, not a maybe.

**5. No category breakdown in this slice.**

`summarize`'s signature is additive (`advance_shares` keyed by transaction id,
mirroring `event_total`), so extending it to also group by
`effective_category` is a later, backward-compatible change once there is a
concrete reason to build it — categorization exists now
(`domain/categories.py`), which unblocks the breakdown in principle, the same
situation `docs/decisions/0005-categorization-rules.md`'s event-totals note
already described. Tracked in `tasks/backlog.md`.

## Consequences

- `GET /dashboard/summary` is read-only: no migration, no new persisted state.
  The endpoint recomputes from `Transaction`/`Advance`/`Reimbursement` on every
  call, same as `GET /events/{id}` recomputes its total.
- `services/advances.py::spending_shares` now has three callers
  (`GET /transactions`, `GET /events/{id}`, `GET /dashboard/summary`) and one
  implementation; a future change to how a write-off affects spending changes
  in one place.
- The SwiftUI dashboard screen is deferred to the M3 client catch-up, same as
  every other M1-tail/M2 backend slice — nothing to render yet since the
  client has no transactions or events UI either.
- M2's roadmap "done when" is met on the backend: an advance's own share, not
  its full amount, is what the summary reports.

## Alternatives considered

- **A single combined total across all currencies, converted at some rate.**
  Rejected outright: Traccio does no FX conversion anywhere (`docs/domain.md`),
  and a conversion rate introduces a second, disputable source of truth for a
  number the roadmap wants to be simply correct.
- **Raise on a mixed-currency period, like `event_total` does for a mixed
  event.** Rejected: an event is expected to be one occasion in one currency;
  a dashboard period is not — spending in two currencies within a month is
  ordinary, not an input error.
- **Fold the category breakdown into this slice since categorization already
  exists.** Rejected for scope: the roadmap's M2 "done when" only requires the
  net figure to reflect `effective_amount`; the breakdown is a real
  improvement but a separate, additive change (see Decision 5).

## Revisit when

- A category breakdown is needed: extend `summarize` to also group by
  `effective_category`, following the same additive pattern
  `advance_shares` already established.
- The M3 client catch-up builds the dashboard screen: it consumes
  `GET /dashboard/summary` as-is: per-currency, magnitudes plus one signed
  net, no client-side derivation (`client/CLAUDE.md`: "the backend owns every
  derived value").

## Revision — 2026-08-24: category breakdown

Both "Revisit when" items above are done. `domain/dashboard.py::summarize`
now also groups by `effective_category`, exactly the additive extension
Decision 5 anticipated — `advance_shares` unchanged, one new
`CategorySummary` per category (plus a fixed `category_id = None` bucket)
nested inside each `CurrencySummary` as `by_category`, never beside it (a
category cannot span currencies, same reasoning as Decision 2). Category
*names* are resolved by the router at read time, not carried on the domain
`CategorySummary` — the aggregation stays free of a repository dependency,
consistent with `domain/` importing nothing.

The client's Panoramica screen now renders the mockup's "Per categoria" donut
and legend (`docs/design/canvas/Main.dc.html`, previously "Concept · richiede
backend"), unblocking the second of the two `#Preview` gaps that badge was
tracking — the trend line (`Andamento netto`) remains open, still needing its
own granularity decision (see `tasks/backlog.md`).

## Revision — 2026-08-25: daily trend

The remaining "Concept" gap. Granularity settled as **daily**
(`tasks/backlog.md`'s M3 iPhone-trial roadmap), and the metric is **spending**,
not the mockup's net line — the daily question that matters is "how much did I
spend," and a net figure at daily granularity is almost always pure spending
with isolated spikes on payday, which reads as noise rather than a trend.

Third additive partition on `summarize`, same shape as Decision 5's category
breakdown: a new `DaySummary` (no `net`, same YAGNI reasoning as
`CategorySummary`) nested inside each `CurrencySummary` as `by_day`, never
beside it — a day cannot span currencies either. The bucketing key is the UTC
calendar day of `coalesce(booked_at, value_date)` — the exact same expression
`list_transactions_in_period` filters on, so a row can never be counted in the
period but excluded from every bucket, or vice versa. This is also `by_day`'s
one departure from `by_category`'s invariant: a transaction with **neither**
`booked_at` nor `value_date` set has nowhere to bucket and is excluded from
`by_day`, while still counted in the currency's own totals — `by_category`
never has this gap, because "no category" is itself a real bucket
(`category_id = None`), but "no day" has no analogous bucket to fall into.

The client's `TraccioCore.dailyBars(_:)` fills every day between the earliest
and latest entry in `by_day` with a zero bar, so the chart never renders
unevenly spaced bars — but it does **not** extend the axis to the full
requested period. `MonthPeriod` (the period picker) is in local time, while
`by_day` is bucketed in UTC days; reconciling the two would risk a day
silently falling outside the client-drawn axis. The axis is therefore
whatever `by_day` actually returned, not the nominal calendar month — a
period picked as "August" in a non-UTC timezone can show a day from the very
end of July or the start of September at its edge. Accepted as the honest
reading of what the backend actually bucketed, rather than a client-side
reinterpretation into local days that the backend never computed.

The client's Panoramica screen now renders this as "Spesa giornaliera" bars
(`docs/design/canvas/Main.dc.html`, badge removed), closing the roadmap's M3
item 4.
