# 0029 — Meal vouchers: a voucher-kind account, excluded and reported separately

Status: accepted
Date: 2026-09-11

## Context

ADR 0023's Satispay import already splits a mixed row into two movements on
two manual accounts — a balance leg and a "Buoni Pasto" leg — because the
user wants both "bags" of money tracked, not folded together. But nothing
downstream knows the second account *is* meal vouchers: `AccountKind` has no
`voucher` member, only the presentation-level `AccountIcon.VOUCHER` exists.
So voucher spend is silently counted inside "Speso questo periodo" like any
other spend, with no way to see how much of the period's total came from
vouchers rather than the user's own money.

The user wants a dedicated "Buoni pasto" summary on Panoramica — spent, how
many movements, and the category breakdown — visible only for someone who
actually receives meal vouchers. Not everyone does, so this must be
opt-in per user, not detected or always on.

## Decision

**1. The signal is the account, not a per-transaction marker.** A new
`AccountKind.VOUCHER` (`domain/enums.py`), alongside `current`/`savings`/
`card`/`wallet`/`cash`. Every transaction on a voucher-kind account is
voucher spend; there is no mixed-instrument transaction (a real card+voucher
split, e.g. a mensa payment, already arrives as *two* transactions if the
user records it that way — same as the Satispay import's two-leg split). A
per-transaction "paid with vouchers" field was considered and rejected: it
would be a new axis with a hook needed in `effective_amount`, disproportionate
to a case ADR 0023's account-level split already covers. `"voucher"` is 7
characters, same length as `"current"`/`"savings"` — the longest existing
`AccountKind` member — so `_enum_column`'s `VARCHAR` needs no widening
migration.

Only ever a manual account, same reasoning as `AccountKind.CASH` — there is
no bank feed for meal vouchers. `POST /accounts/{id}/kind` is new: the only
way to turn an *existing* account (e.g. one created `cash` before this
feature, or by the Satispay import) into `voucher` without deleting and
recreating it, which `DELETE /accounts/{id}` refuses once the account holds
movements (`409 account_not_empty`). Gated `409 account_not_manual` for a
synced account, mirroring the delete endpoint's gate — a synced account's
`kind` is provider-derived and only a sync may write it.

**2. A second per-user setting, `users.meal_vouchers_enabled BOOLEAN NOT
NULL DEFAULT false`.** Alongside `tracking_start_date` (ADR 0024) — still on
the `users` table, not a `user_settings` table: two scalar settings still fit
comfortably as columns, and a table earns its keep at a third, or the first
one with real structure. Unlike `tracking_start_date`, this column is `NOT
NULL` — there is no third state between on and off, so
`server_default=false` backfills every existing row to "off" (identical to
before this column existed). `GET/POST /settings` already exist (ADR 0024)
and now return both settings; `POST /settings/meal-vouchers` is a **separate**
endpoint rather than a second field folded into `SetTrackingStartRequest` —
that body is deliberately mandatory-but-nullable so "clear the date" is never
ambiguous with "leave it alone", and a plain optional boolean on the same
body would reintroduce exactly that ambiguity for this setting.

**3. Exclusion from the dashboard's headline totals is a scoping filter, not
a second derivation.** The root architectural rule is that `effective_amount`
is the one place spending is derived, and the dashboard aggregates from it
alone (ADR 0007). This decision does not touch that: `voucher_account_ids`
is resolved from the user's accounts, and
`domain.dashboard.split_meal_voucher_transactions` (pure, no I/O) removes
those transactions from the list *before* `summarize` ever sees them — the
same category of thing ADR 0024's tracking-start floor already does. The
router then calls `summarize` a second time, over exactly the transactions
the split set aside, to build the "Buoni pasto" breakout — one aggregation
function, two calls, no parallel code path. Both `found` and `compare_found`
are split identically, so a period-over-period comparison stays apples-to-
apples; FX conversion (ADR 0021) runs on the already-filtered `found`, so
`converted` excludes voucher spend too, and the breakout itself is **never**
FX-converted — a per-currency addition, exactly like `currencies` itself,
never summed into one base-currency figure.

**4. The card shows spent, movement count, and category breakdown — nothing
else.** `MealVoucherSummaryResponse` (`currency`, `spending`, `income`,
`transaction_count`, `by_category`) reuses `CategoryGroupSummaryResponse`, so
the per-category split comes free from the same `summarize` call — no new
aggregation code. No residual balance (would need a stronger claim about what
a voucher account's `balance` field means, which this decision does not make)
and no daily-average (would need a per-voucher euro value the user has not
supplied). `DashboardSummaryResponse.meal_vouchers` defaults to `[]` — empty
when the setting is off, there is no voucher account, or nothing was spent —
which is exactly the user's "se sono stati spesi" (only if something was
actually spent).

**5. The toggle is a true revert.** With `meal_vouchers_enabled = false`, a
voucher-kind account behaves like any other account again: counted in
`spending`/`income`, listed in "Per conto", no card. Nothing about a voucher
account's data changes when the setting flips — only which bucket the
dashboard router puts its transactions in. Turning the setting on, in
contrast, changes what the historical dashboard figures show: any period
that includes voucher spend will show a smaller "Speso questo periodo" the
moment the setting is turned on, with the difference now visible in the new
card instead. This is the deliberate cost of the feature, not a bug.

## Consequences

- Backend: `AccountKind.VOUCHER`; `POST /accounts/{id}/kind` +
  `SetAccountKindRequest` + `set_account_kind`; migration
  `a4b6c8d0e2f4_user_meal_vouchers_enabled` adding
  `users.meal_vouchers_enabled`; `User.meal_vouchers_enabled`;
  `get_meal_vouchers_enabled`/`set_meal_vouchers_enabled` in
  `db/repositories/settings.py`; `current_meal_vouchers_enabled` in
  `api/deps.py`; `SettingsResponse` (renamed from `TrackingStartResponse`) +
  `SetMealVouchersRequest`; `POST /settings/meal-vouchers`;
  `domain.dashboard.split_meal_voucher_transactions`;
  `MealVoucherSummaryResponse` + `DashboardSummaryResponse.meal_vouchers`.
- Client: `AccountKind.voucher` (+ `IconTile` already mapped it to `"ticket"`
  as of the icon vocabulary, unused until now); `SettingsResponse` renamed
  client-side too; a "Buoni pasto" toggle row in Impostazioni; a "Tipo" picker
  on `AccountEditorSheet` for manual accounts, switched to `.menu`
  (a 6th segmented-control item no longer fits); `MealVoucherCard` on
  Panoramica, reusing `CategoryBreakdownRow.breakdownRows` /
  `CategoryBreakdownList` — no drill-through, same reasoning
  `AccountBreakdownCard` already documents (`GET /transactions` has no
  voucher-account filter).
- `docs/domain.md`: §Account (the new kind) and §User (the second per-user
  setting).
- Filed to `tasks/backlog.md`, not done here: a `voucher_account_id` filter
  on `GET /transactions` (would enable the card's drill-through), and
  pointing ADR 0023's import voucher-account picker at existing
  `AccountKind.VOUCHER` accounts first.

## Alternatives considered

- **Per-transaction "paid with vouchers" marker.** Rejected: a new axis on
  `Transaction` with a hook needed in `effective_amount`, for a case the
  account-level split (ADR 0023) already covers without one.
- **Detect meal-voucher accounts automatically** (e.g. from the Satispay
  import's voucher leg). Rejected: fragile (only covers the one import path)
  and unnecessary — the user already knows which of their accounts is meal
  vouchers and can set the kind explicitly, same as any other account kind.
- **Include voucher spend in the headline total, break it out as an
  additional line only.** Rejected by the user: they want the two "bags"
  kept genuinely separate on the dashboard, not double-counted.
- **A `user_settings` table for `meal_vouchers_enabled`.** Rejected for the
  same reason ADR 0024 rejected it for `tracking_start_date`: one more scalar
  column is cheaper than a table, revisit at a third setting.

## Revisit when

- A third per-user setting appears — then a `user_settings` table (or a JSON
  column) is worth it.
- The user wants a residual-balance or per-voucher-value figure on the card —
  needs a real decision about what a voucher account's `balance` means and
  where the per-voucher euro value comes from, neither settled here.
- `GET /transactions` grows an `account_id`/`voucher` filter for another
  reason — then the card's drill-through is worth adding too.
