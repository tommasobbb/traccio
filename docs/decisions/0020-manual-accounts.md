# 0020 — Manual accounts as bank-less rows, editable by row origin not status

Status: accepted
Date: 2026-08-27

## Context

A few days of real daily use surfaced a gap: money that never touches a
synced bank account — cash in a wallet ("Contanti"), or money parked in an
investment pass-through the user reconciles by hand ("Investimenti") — has
nowhere to live in Traccio. Every account today is a projection of a bank
feed: `accounts.connection_id`, `accounts.identification_hash`, and
`transactions.account_id` are all `NOT NULL`, and the only transaction write
paths are `set_confirmed_category` / `set_suggested_categories` and
`prune_stale_pending_transactions` — there is no create, edit, or delete of a
movement itself.

The product decision was taken with the user directly (`tasks/backlog.md`,
"Feature ideas from real daily use", 2026-08-27): **full manual accounts with
real, hand-entered transactions**, not a lightweight "exclude this movement
from stats" tag. The user wants actual cash tracking, not a way to hide
numbers. It is explicitly **not** net-worth or portfolio tracking
(`tasks/ROADMAP.md` §"Explicitly not planned" still holds) — a manual
"Investimenti" account is a pass-through ledger for money that left the
tracked accounts, nothing more.

The backlog left three modeling options open: a new `AccountKind.MANUAL`, a
nullable `connection_id`, or a separate entity. This ADR records the choice
and the rules that fall out of it.

## Decision

### 1. `connection_id` and `identification_hash` become nullable, together

A manual account has no consent and no provider-assigned identity, so both
columns go `NULL` for it. `Account` gains a `model_validator` that enforces
the only two legal shapes: **both set** (a synced account) or **both `None`**
(a manual account). A half-populated `Account` fails to construct — illegal
state unrepresentable, per `docs/engineering.md`.

`AccountKind.MANUAL` was rejected: `kind` answers *what type* of account this
is (current / savings / card / wallet / cash), an axis orthogonal to *where
it comes from*. A manual account still has a kind. Folding origin into the
kind enum would make `kind` mean two things and force every `kind` check to
also reason about provenance.

A separate entity was rejected: it would duplicate everything that already
hangs off `accounts` — the `transactions.account_id` FK, the dashboard
`by_account` partition, the Movimenti account filter, the appearance
columns — for no gain over one nullable pair guarded by a validator.

**Free consequence, and the reason this shape is safe:** `upsert_account`
matches on `(user_id, identification_hash)`, and in SQL `NULL != NULL`. A
sync can therefore never match, adopt, or overwrite a manual account — this
is structural, not a discipline a future change could forget. `services/sync.py`
also only ever iterates `provider.list_accounts()` output, never the DB's own
`list_accounts`, so a manual row is never even a candidate.

### 2. `AccountSource` is derived, never stored

A new `domain/accounts.py::account_source(account)` returns
`AccountSource.SYNCED` when `connection_id` is set, else
`AccountSource.MANUAL`. Exposed on `AccountResponse.source`. Same discipline
as `derive_advance`'s `settled` (ADR 0004) and `consent_state` (ADR 0006):
if it can be computed from stored fields, it is not itself a stored field
that could drift.

### 3. New `AccountKind.CASH`

The user named "Contanti" and none of the four existing kinds fits. `wallet`
means a specific thing (`docs/domain.md`: a currency-agnostic multi-currency
wallet like PayPal, reporting `XXX`) and is not stretched to cover a cash
float. No migration — enum columns are portable `VARCHAR` with no check
constraint (precedent: `WALLET`, 2026-08-20), and `cash` (4 chars) fits the
existing `VARCHAR(7)` on `accounts.kind`.

No `INVESTMENT` kind is added: `tasks/ROADMAP.md` rules out portfolio
tracking, and an "Investimenti" pass-through is modelled as a manual `wallet`
or `current` account whose meaning is carried by its `alias` and `icon`
(ADR 0017), not by a bespoke kind.

### 4. A manual account's name is its `alias`, not `name`

`name` is by definition the provider's product name
(`docs/domain.md` §Account) and stays `NULL` for a manual account.
`display_name(account)` already resolves `alias ?? name`, so
`GET /accounts` needs no change to show a manual account's name, and
`POST /accounts/{id}/rename` is already the rename endpoint for it — no new
endpoint. `POST /accounts/{id}/appearance` likewise already covers colour and
icon.

### 5. Manual transaction identity: `KeyStrategy.MANUAL`, key is the row id

A hand-entered movement has no `entry_reference` and no meaningful derived
hash (two identical cash entries on the same day are legitimately two
movements, not a collision to dedupe). A new `KeyStrategy.MANUAL` records the
provenance, and `stable_key` is `str(transaction.id)` — unique by
construction within the `(account_id, stable_key)` constraint, and stable
across edits because an edit never changes the id.

### 6. Manual transactions are always `booked`

There is no pending→booked lifecycle without a bank. Creating a manual
transaction always sets `status = booked`. This keeps manual rows entirely
outside `prune_stale_pending_transactions` (which only touches `pending`
rows, and additionally reads `last_synced_at`, which is `NULL` for a manual
row and already treated as "not yet eligible").

### 7. Editability is decided by row origin, not by `status`

`docs/domain.md` §Transaction said "immutable once `booked` — corrections
arrive as new transactions, never as edits." That rule exists because **the
bank is the source of truth** for a synced row. It does not apply to a row
the user typed. The rule is restated: a transaction on a **synced** account
is immutable; a transaction on a **manual** account is the user's and is
editable and deletable.

Because a sync can never touch a manual account (decision 1), the account's
origin unambiguously determines the movement's origin — so **no new column on
`transactions`**. The write endpoints check `account_source` of the owning
account and refuse with `409` on a synced one.

### Endpoints

| Method & path | Purpose |
| --- | --- |
| `POST /accounts` | Create a manual account (`alias`, `kind`, `currency`, optional `color`/`icon`). |
| `DELETE /accounts/{id}` | Delete a manual account. `409 account_not_manual` on a synced one; `409 account_not_empty` if it has any transaction. |
| `POST /transactions` | Create a movement on a manual account (`account_id`, `amount`, `currency`, `value_date`, `description`, optional `confirmed_category_id`). |
| `POST /transactions/{id}/edit` | Edit a manual movement (same fields except `account_id`). `409 transaction_not_manual` on a synced row. |
| `DELETE /transactions/{id}` | Delete a manual movement. `409 transaction_not_manual`; `409 transaction_in_use` if it is a leg of a transfer / advance / reimbursement. |

`409 account_not_empty` and `409 transaction_in_use` follow the
`409 category_in_use` precedent: refuse rather than cascade-delete financial
data. The FK references to guard against a `transaction` delete are
`transfers.outgoing/incoming_transaction_id`,
`transfer_dismissals.transaction_id_a/b`, `advances.transaction_id`, and
`reimbursements.transaction_id`.

## Consequences

- **Client compatibility is a required, minimal companion change.** The
  installed iPhone build decodes `AccountResponse.connection_id` as a
  non-optional `UUID` and rejects an unknown `AccountKind`. The moment a
  manual account exists, `GET /accounts` would fail to decode. This ADR's
  slice therefore also makes `AccountResponse.connectionID` optional and adds
  `AccountKind.cash` in `TraccioCore`, with matching decode tests, and
  regenerates `docs/api/openapi.json`. **No client UI** — the create/edit
  screens are a separate, later task (the user's explicit call).
- `AccountResponse` gains `connection_id: UUID | None` and `source`. Both are
  additive; `source` lets the client show a manual account without inferring
  it from a null.
- `Connections/ConnectionGroup.groupByConnection` on the client already drops
  an account with no matching connection into a trailing "no connection"
  group, so a manual account renders in Conti without a crash — under a
  bank-shaped header. Fixing that presentation is the later UI task, not this
  one.
- `docs/domain.md` §Account (the new `cash` kind, accounts without a
  connection) and §Transaction (decision 7) are updated;
  `docs/architecture.md` gains a line that a sync cannot reach a manual
  account.
- No behaviour change for any existing synced account or transaction: every
  new column value is `NULL`/absent for them, and every new endpoint refuses
  to act on them.

## Alternatives considered

- **`AccountKind.MANUAL`.** Rejected — conflates the "what kind" and "what
  origin" axes; a manual account still has a real kind, and every existing
  `kind` branch would have to learn about provenance.
- **A separate `ManualAccount` / `ManualTransaction` entity.** Rejected —
  duplicates the `transactions` FK, the dashboard `by_account` partition, the
  Movimenti filter, and the appearance columns, to avoid one nullable pair.
- **Synthetic `identification_hash` (e.g. `manual:<uuid>`) to keep the
  column `NOT NULL`.** Rejected — it is a fake value that exists only to
  dodge a schema change, and it would sit in the `(user_id,
  identification_hash)` unique index pretending to be a provider identity. A
  real `NULL` says what is true.
- **A dedicated `is_manual` boolean on `transactions`.** Rejected —
  redundant. The owning account's `connection_id` already answers it, and a
  sync cannot desynchronise the two because it never writes a manual account.
- **Relax the "`booked` is immutable" rule globally so edits work
  everywhere.** Rejected for the same reasons as ADR 0019: the rule protects
  bank-sourced truth. Scoping editability to manual rows keeps synced history
  exactly as immutable as it is today.

## Revisit when

- A manual transaction needs to be a leg of a **manual transfer** — that is
  the next backlog item (free-form transfer pairing). It only needs the
  `409 transaction_in_use` guard here to already know about `transfers`,
  which it does.
- A user wants to convert a manual account into a synced one (or vice
  versa). Out of scope now; the validator would need a documented transition
  path rather than the current hard either/or.
- Foreign-currency manual transactions plus the dashboard FX-conversion item
  interact — a manual movement can already carry any `currency`, so it will
  land in the existing "unsummed foreign currency" bucket until FX conversion
  ships.
