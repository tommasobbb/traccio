# 0019 — Repairing already-synced rows with a one-off script, not a relaxed write path

Status: accepted
Date: 2026-08-27

## Context

Real use surfaced PayPal movements showing up with no date and no
description. Investigation found the mapper
(`providers/enable_banking/transactions.py`) only read `booking_date`,
`value_date`, and `remittance_information`; PayPal sends the first two always
`null` and the third an always-empty list, so every PayPal transaction landed
with `booked_at`, `value_date`, and `description` all empty. This is worse
than cosmetic: `db/repositories.py::_transaction_when()` is
`coalesce(booked_at, value_date)`, so a row with both `null` is excluded by
any date-bounded query — the entire PayPal history was invisible in every
Panoramica period and every date-filtered Movimenti view, silently.

The mapper itself was fixed with a general fallback chain (not a PayPal
branch, `.claude/rules/python.md`): `value_date` falls back to
`transaction_date`, and `description` falls back to the counterparty's name
on the side implied by `credit_debit_indicator` — see
`docs/openbanking.md`'s normalization bullets and per-bank table for the
mapping this now records. But `upsert_transaction` returns an existing
`booked`/`rejected` row **untouched by design**
(`docs/domain.md`: terminal rows are immutable, corrections arrive as new
transactions) — so the mapper fix helps nothing already persisted. Fixing the
141 already-synced PayPal rows needed a second decision, which is what this
ADR records.

## Decision

**Repair with a one-off script (`scripts/repair_empty_transaction_fields.py`)
that re-fetches through the now-fixed mapper and fills only currently-empty
fields, rather than relaxing terminal-row immutability to let a normal sync
overwrite them.**

Relaxing immutability was seriously considered. One can honestly argue that
filling a `NULL` *completes* a record rather than *edits* one — a stated
value was never overwritten, since there was no value to overwrite. It was
rejected anyway:

- It contradicts `docs/domain.md` §Transaction, `docs/openbanking.md`
  §Persistence, and `upsert_transaction`'s own docstring, all of which state
  the immutability rule without carving out "unless the field was empty" as
  an exception.
- It permanently widens the write path: any future mapper change would
  silently rewrite history for every row matching its blast radius, not just
  today's three known-empty fields. A one-off script's blast radius is
  exactly what its own code says and nothing more.
- **It has no coverage upside.** PayPal, like most Open Banking providers,
  only serves a rolling history window after the initial post-authorization
  grant (`docs/openbanking.md`'s operational constraints). A relaxed sync
  would hit the exact same ceiling a one-off re-fetch does — there is no
  extra history to gain by making the write path permanent.

The script (`plan_repair`, `repair_account`, tested in
`tests/test_repair_empty_transaction_fields.py` — the one script in
`scripts/` that writes production data, so unlike `eb_smoke.py`/
`eb_field_census.py` it earns a test):

- Finds terminal rows with at least one empty repairable field
  (`booked_at`/`value_date` `NULL`, or `description` `""`).
- Re-fetches through `BankProvider.fetch_transactions` — the same path a
  normal sync uses, so field mapping cannot drift between the two.
- Matches a stored row to a fresh one by `stable_key`, the same identity
  `upsert_transaction`'s unique constraint uses.
- Fills a field only where the stored value is empty **and** the fresh value
  is populated — never overwrites a populated field, never touches `amount`,
  `currency`, `status`, `entry_reference`, `key_strategy`, `role`,
  `display_description`, `event_id`, or either category id.
- Defaults to a dry run; `--apply` commits. Idempotent — a second `--apply`
  reports `rows_updated=0`.
- Is general, not PayPal-specific: it repairs any account through whichever
  adapter `build_bank_provider()` returns, whatever bank sent the empty
  fields.

**The `~90`-day ceiling is accepted knowingly.** Re-running SCA for a fresh
full-history authorization was offered and declined — the older PayPal
history stays dateless permanently. The script's `rows_unmatched` count
reports this honestly rather than hiding it: a row the bank no longer serves
stays exactly as empty as before the script ran.

## Consequences

- Production repair (2026-08-27): all 141 PayPal rows still fell inside the
  bank's serving window — 141/141 matched, 141 `value_date` filled, 140/141
  `description` filled (1 entry had no remittance and no counterparty name
  either), 0 `booked_at` filled (by design — see below). A second `--apply`
  run reported `rows_updated=0`, confirming idempotency on real data.
- **`booked_at` gets no fallback and stays `None` for these rows,
  permanently.** `None` is the modelled "not yet settled" signal;
  `_transaction_when()` already owns the display-level
  `coalesce(booked_at, value_date)` in the right layer, and populating
  `value_date` alone already fixes the visibility bug. A pinned test
  (`test_booked_at_has_no_fallback_even_when_transaction_date_present`)
  guards this from being "fixed" by accident later.
- `POST /rules/apply` was run once after the repair to categorize the newly
  described rows against the user's rules — no new code, the existing
  explicit idempotent recompute.
- `docs/openbanking.md`'s PayPal row and its two normalization bullets are
  corrected: `remittance_information` is absent in practice (an always-empty
  list), not "rich" as originally recorded; `merchant_category_code` is
  always `null`; `booking_date`/`value_date` are always `null`;
  `transaction_date` is PayPal's only date source.

## Alternatives considered

- **Relax terminal-row immutability to let a normal sync fill empty
  fields.** Rejected — see Decision above: contradicts three documented
  invariants, permanently widens the write path, and buys no extra coverage
  over a one-off script.
- **Re-run PayPal's SCA for a fresh full-history window.** Declined by the
  user — would recover more of the older history, but at the cost of
  re-authorizing a live consent for a one-off repair. The ~90-day ceiling is
  accepted instead.
- **Do nothing, since the mapper fix already stops new rows from breaking.**
  Rejected — leaves 141 already-real, already-used transactions permanently
  invisible in the exact views the user reported the bug from.

## Revisit when

- A second provider surfaces the same "already-synced rows need backfilling"
  need — at that point `repair_empty_transaction_fields.py`'s pattern
  (re-fetch through the real adapter, match on `stable_key`, fill-if-empty)
  should generalize cleanly; nothing here is PayPal-specific already.
- `merchant_category_code` turns out to be well populated for some bank —
  filed separately in `tasks/backlog.md` as a categorization-rule input, out
  of scope here (it's a code, not text, so it never belongs in
  `description`).
