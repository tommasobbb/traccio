# 0021 — FX conversion in the dashboard: opt-in, additive, ECB rates

Status: accepted
Date: 2026-08-27

## Context

`GET /dashboard/summary` returns one summary per currency and never sums
across them (ADR 0007 Decision 2). ADR 0007's Alternatives section rejected
"a single combined total across all currencies, converted at some rate"
**outright**, because "a conversion rate introduces a second, disputable
source of truth for a number the roadmap wants to be simply correct."

Real daily use changed the calculus. The synced accounts already span EUR /
CHF / TRY, and ADR 0020's manual accounts accept **any** currency — so
Panoramica now shows a headline figure *per currency* and no combined
picture at all. The user asked for a converted total, accepting the
tradeoff. This ADR records what was agreed and bounds the reversal so the
"simply correct" property ADR 0007 protected is not lost — only supplemented.

## Decision

**1. The per-currency breakdown is unchanged and remains the source of
truth.** `summarize` still groups by transaction currency; `currencies` in
the response is byte-for-byte what it was. The converted view is a **new,
optional, sibling** field (`converted`), never a replacement. ADR 0007
Decision 2 still stands as written; this ADR adds a second lens beside it.

**2. FX is dashboard-only and opt-in.** `TRACCIO_FX_ENABLED` defaults to
`false` — the app boots with no `.env` and makes no outbound call to a rate
API unless this is deliberately switched on, exactly like
`background_sync_enabled` (ADR 0010) and `send_psu_headers` (ADR 0011).
Events stay single-currency (`docs/domain.md` §Event, `domain/events.py`
unchanged) — a mixed-currency event still has no single total and is
refused.

**3. Rate source: frankfurter.dev.** Free, no API key, ECB reference rates,
historical and range endpoints, self-hostable. `httpx` is already a
dependency, so this adds **no new package** — only a small
`FrankfurterClient` on the `EnableBankingClient` pattern (one HTTP choke
point, `transport=` seam for tests, errors wrapped value-free). The base URL
is a setting (`TRACCIO_FX_API_BASE_URL`); there is no secret to manage on
Fly.

**4. Conversion basis: historical, per transaction date.** Each movement is
converted at the ECB rate for its `coalesce(booked_at, value_date)` — the
same "when" the period filter and every bucket already use. This is the
honest number: a USD 100 purchase stays what it actually cost, and last
month's total does not drift as today's rate moves. The ECB does not publish
on weekends/holidays, so "the rate on or before date D" is used. A movement
with **no date** uses the latest available rate. Conversion happens
**before** `effective_amount` and `summarize` run: each `Transaction.money`
(and each advance's own-share `Money`) is rewritten into the base currency,
then a second `summarize` pass produces one `CurrencySummary` in the base —
`by_category` / `by_bucket` / `by_account` / `comparison` all converted for
free, with no parallel aggregation to keep in sync.

**5. Best-effort.** If any rate a period needs cannot be obtained (the API is
down *and* the cache lacks it, or a currency has no ECB rate at all),
`converted` is `null` and `conversion_unavailable` carries a stable,
value-free reason (`rates_unavailable` / `missing_rate`). The endpoint never
returns 5xx for an FX failure and never returns a partial or approximate
converted total. `currencies` is always present and complete.

**6. `fx_rates` is reference data, not user data.** It is the one persisted
table not scoped by `user_id` — ECB rates are public and identical for every
user, the same category as the seeded `Category` templates
(`docs/domain.md`'s stated exception to "every query is scoped by
user_id"). Historical rows are immutable once fetched; only the row for the
most recent ECB date is re-fetched, and only when its `fetched_at` is older
than `TRACCIO_FX_RATE_TTL_HOURS`. A `rate` is stored as an exact **decimal
string** (`Text`), never a float and never `Numeric` — consistent with
"money is integer cents, never float."

**7. Rounding.** `amount_cents * rate` is rounded half-up to integer cents
(`Decimal`, `ROUND_HALF_UP`). Summing many independently-rounded movements
can drift from converting the grand total by a cent or two; this is accepted
and noted, the same order of imprecision any per-line currency conversion
carries.

## Consequences

- New: `TRACCIO_FX_ENABLED` / `TRACCIO_FX_BASE_CURRENCY` (default `EUR`) /
  `TRACCIO_FX_API_BASE_URL` / `TRACCIO_FX_RATE_TTL_HOURS` settings; a
  `fx_rates` table + migration; a pure `domain/fx.py`; a `services/fx.py`
  orchestrator; a `providers/frankfurter.py` client; `converted` /
  `conversion_unavailable` on `DashboardSummaryResponse`.
- `docs/domain.md` §Dashboard and the "no FX in Traccio" docstrings in
  `domain/dashboard.py` / `api/schemas/dashboard.py` /
  `api/routers/dashboard.py` are updated to "one summary per currency; a
  converted combined total is available opt-in and additive (ADR 0021)".
- Zero behaviour change with the flag off: every existing dashboard test
  stays green because `converted` defaults to `null` and is only computed
  when `TRACCIO_FX_ENABLED` is set.
- The client change (a converted hero card in Panoramica) is a **separate
  slice** (`tasks/backlog.md` item 5a) — this slice is backend-only, and the
  Swift `DashboardSummaryResponse` model simply ignores the new field until
  then.
- ADR 0007 gets a pointer: its "no converted total" alternative is now
  superseded by this ADR for the dashboard.

## Alternatives considered

- **A single latest-rate snapshot** (convert everything at today's rate).
  Rejected: last month's total would change every day as rates move — the
  exact "second disputable source of truth" ADR 0007 warned about. Historical
  per-date rates make a past total stable.
- **No persistence — fetch on every dashboard load.** Rejected: historical
  ECB rates are permanent once known; re-fetching the same 30-day range on
  every render wastes an external call and adds latency and a hard
  dependency to a screen that must still work when the rate API is briefly
  down. The cache table makes a brief outage invisible.
- **A `RateProvider` ABC** (Strategy, like `BankProvider`). Rejected by
  YAGNI (`.claude/rules/python.md`): there is exactly one rate source and no
  concrete second one on the horizon. A module of functions plus a
  settings-driven base URL is the house style until a second source is real.
- **A user-facing base-currency setting screen.** Deferred: there is no user
  preferences store yet, and the user has one realistic base currency
  (`EUR`). A config setting now, a per-request `convert_to` param or a
  preference later if it matters.

## Revisit when

- A second rate source becomes real (a paid feed, an offline bundle) — then
  `providers/frankfurter.py` grows into an ABC with `FrankfurterProvider` as
  one implementation, following `BankProvider`'s shape.
- The user wants a base currency other than `EUR`, or per-user: add a
  `convert_to` query param (stateless, like `tz`) or a preferences table.
- Manual accounts make foreign-currency spending common enough that the
  converted view should be the *default* headline rather than an opt-in
  addition — at which point `TRACCIO_FX_ENABLED` defaults flip and the
  Panoramica hero leads with `converted`.
