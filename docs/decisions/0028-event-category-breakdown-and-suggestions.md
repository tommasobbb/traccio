# 0028 — Event: a category breakdown and date-range suggestions

Status: accepted
Date: 2026-09-09

## Context

An `Event` (`docs/domain.md` §Event) has, until now, exposed exactly one
derived number — the net `total`. The first question the feature gets in daily
use is *"Turkey 2026: how much on transport, how much on food?"*, and the
Eventi screen could not answer it. Two backlog items covered this:

- **Event totals broken down by category** — unblocked since categorization
  shipped (2026-08-21), never built.
- **Event membership suggestions from the date range** — `start_date` /
  `end_date` are stored as hints but nothing consumed them; `AddEventMembersSheet`
  could only pick from the most-recent 100 transactions, so an event from six
  months ago was impossible to populate.

## Decision

### 1. The breakdown reuses the dashboard's own aggregation — no new domain code

`domain/dashboard.py::summarize` already takes a sequence of transactions,
`advance_shares`, and `parents`, and returns a `CurrencySummary` per currency
whose `by_category` is ADR 0018's two-level hierarchy. **An event's members
*are* a sequence of transactions.** So `GET /events/{id}/summary` is:

```
members  = list_event_members(...)                     # already exists
shares   = _advance_spending_shares(..., members)      # already exists in this router
parents  = {c.id: c.parent_id for c in list_categories(...)}
summary  = summarize(members, advance_shares=shares, parents=parents)[0 or None]
```

`event_total` is **not** extended — it stays the single net figure; the
breakdown is a different, richer read. An event is single-currency by
construction (`assign_transaction` refuses a `mixed_currency` member), so
there is exactly one `CurrencySummary`; an empty event yields
`{spending: 0, income: 0, net: 0, currency: null, by_category: []}`.

`EventSummaryResponse` carries `spending` / `income` / `net` / `currency` plus
`by_category: list[CategoryGroupSummaryResponse]` — the dashboard's own
response type, imported unchanged. The client therefore renders it with the
**same** `DonutChart`, `CategoryBreakdownList`, `BreakdownRowView`, and the
pure `TraccioCore.donutSegments` / `breakdownRows` — zero new chart code.

`net` here equals `EventResponse.total`; the two endpoints agree because they
sum the same `effective_amount` over the same members.

### 2. Drill-through reuses the dashboard's cross-tab mechanism

A breakdown row drills through to Movimenti filtered to **this event and that
category** — `TransactionFilter(eventID:, category:)`, both parameters already
on `GET /transactions`. `EventDetailView` lives in the Impostazioni tab's
stack (ADR 0009); rather than nest a `TransactionsView` (its own
`NavigationStack`) inside that stack, it uses the same `TransactionsDrillThrough`
environment object the dashboard uses — already provided on the whole
`TabView` — which switches to the Movimenti tab pre-filtered. No `TraccioApp`
change. The direct-remainder row stays non-tappable, the same reason ADR 0008's
2026-08-26 revision documents for the dashboard.

### 3. Suggestions *suggest*, and only from a full date range

`GET /events/{id}/suggestions` returns un-grouped (`event_id IS NULL`)
transactions whose `coalesce(booked_at, value_date)` falls within
`[start_date, end_date]`, most recent first, capped at 200. A dedicated
repository read — `list_event_candidates` — rather than another parameter on
`list_transactions` (already ten): one module, one responsibility.

- **An event without *both* bounds set returns an empty list**, not an error —
  the range is a hint, and half a range is no window. `EventEditorSheet`'s
  date toggle reveals both pickers together, so setting one normally means
  setting both.
- **Nothing is auto-assigned.** Each suggestion is added by an explicit tap
  (`POST /events/{id}/transactions`), the same posture as transfer and
  reimbursement matching. "Aggiungi tutti" is a client-side loop over that
  same call, stopping on the first failure.

## Consequences

- New: `EventSummaryResponse` schema (+ `CurrencySummary` projection),
  `GET /events/{id}/summary`, `list_event_candidates` repository fn,
  `GET /events/{id}/suggestions`.
- `api/schemas/events.py` now imports from `api/schemas/dashboard.py`
  (`CategoryGroupSummaryResponse`, `CategoryDisplay`) — the first cross-schema
  import in `api/schemas/`; acceptable, the alternative is duplicating a
  10-field response type.
- Client: `EventSummaryResponse` model, `APIClient.eventSummary(id:)` /
  `eventSuggestions(id:)`, `EventDetailViewModel` gains `summary` /
  `selectedCategory` / `expandedCategoryRootIDs` / `suggestions` and the
  matching loads (reloaded after every membership change), `EventSections`
  gains two `AnyView?` card slots, `EventDetailView` builds the breakdown card
  (reused dashboard views) and the "Movimenti suggeriti" card.
- `EventDetailViewModel.selectedCategory` is typed
  `DashboardViewModel.DonutSelection` — `DonutChart`'s `selection` parameter
  is already that type, so this reuses rather than duplicates it. If a third
  screen needs a donut, that enum should move to `TraccioCore`.

## Alternatives considered

- **Extend `event_total` to group by category.** Rejected: `summarize`
  already does exactly this, over the same inputs, with the hierarchy and the
  display join already solved. Re-deriving it in `domain/events.py` would be
  a second, drifting implementation.
- **A `by_bucket` / trend on the event too.** Not asked for; an event is an
  occasion, not a period you scrub. Skipped.
- **Auto-assign transactions in the date range on event creation.** Rejected
  outright — `docs/domain.md` is explicit that the range suggests, never
  assigns (a flight booked three months early belongs to the trip; a grocery
  run during the same week may not).
- **A single bound widening to "today".** Rejected as surprising — a
  start-only event would suggest months of unrelated movements.

## Revisit when

- The `DonutSelection` type is needed by a third screen — move it down to
  `TraccioCore` then.
- Suggestions need to also consider description/merchant similarity, not just
  the date window (a much larger feature, tied to the deferred `Merchant`
  entity).
