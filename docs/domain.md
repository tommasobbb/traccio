# Domain Glossary

Shared vocabulary for backend and client. When code and this document
disagree, this document is wrong — fix it in the same commit.

Traccio is built multi-tenant from day one, but ships first as a
single-user personal tool. Every entity below except seeded `Category`
templates belongs to exactly one `User`, and no query may return rows
across users — even while that user is only the author. This costs little
now and avoids a rewrite later.

---

## Money

Amounts are **integer cents**, never floating point. `1234` means 12.34 in
whatever currency the sibling field says.

Every amount travels with an explicit `currency` (ISO 4217, e.g. `"EUR"`).
Never assume EUR, even though most accounts will be. An `Account` has one
currency; a `Transaction` carries its own, because card transactions abroad
are settled in a different currency than they were made in.

**Sign convention**: negative means money left the account, positive means it
arrived. This holds for every account type, including credit cards — see
`Account` below, because banks do not agree on this.

---

## User

A person with an account in Traccio. Owns `Connections`, `Accounts`,
`Transactions`, `Rules`, and `Budgets`.

A `User` is not a bank customer identity. One `User` may hold accounts at
several banks, and the same human at the same bank may appear as different
identities across `Connections`.

Every persisted query is scoped by `user_id`. There is no "admin sees all"
path.

---

## Connection

One authorized link between a `User` and one bank (technically, one PSD2
consent obtained through the aggregator).

Key properties:
- `status`: `pending` | `active` | `expired` | `revoked` | `error`
- `expires_at`: consent expiry. For most banks the maximum session lifetime
  is 180 days, after which the user must re-authorize from scratch.
- Credentials/tokens are **encrypted at rest**, never logged, never returned
  by any API endpoint, not even to the owning user.

A `Connection` is not an `Account`. One consent typically exposes several
accounts, and re-authorizing creates a new consent for the same accounts.

**Expiry is a first-class product concern, not an error case.** The client
must surface an upcoming expiry before it happens, because an expired
connection silently stops producing data.

---

## Account

A single balance-bearing account exposed by a bank: a current account, a
savings account, a card account, or a currency-agnostic wallet (e.g. PayPal).

`kind`: `current` | `savings` | `card` | `wallet`

**Wallets have no single currency.** A wallet such as PayPal reports `XXX`
(ISO 4217 "no currency") as its account currency, because it holds balances in
several currencies at once. Traccio stores that `XXX` as-is; the account
currency is only informational for a wallet. The **per-transaction** currency
is authoritative — each movement already carries its own currency, exactly as a
foreign card purchase does.

**Card accounts invert intuition.** Many banks report card transactions with
the opposite sign to current accounts (a purchase as a positive number,
because it increases what you owe). Normalization happens in the provider
adapter, not in services or the client: whatever the bank sends, a purchase
is stored negative. Each adapter documents its own convention.

Not every bank exposes card accounts at all. An account missing from the API
is not a bug to fix in Traccio.

**Stable identity**: bank-assigned account IDs are not stable across
consents. Match accounts across `Connections` using a derived
`identification_hash`, not the provider's account ID.

---

## Transaction

A single movement on an `Account`. Immutable once `booked` — corrections
arrive as new transactions, never as edits.

Fields that matter for identity and behavior:
- `amount` + `currency` (see Money)
- `booked_at`: when the bank settled it. May be null while pending.
- `value_date`: when it affects the balance. Often differs from `booked_at`.
- `description`: raw text from the bank. Preserved verbatim, never rewritten
  in place; cleanup produces a separate `display_description`.
- `status`: `pending` | `booked` | `rejected`

  A `rejected` movement was refused or reversed by the bank and never settled
  (ISO 20022 `RJCT`, first seen in the PayPal ledger). Like `booked` it is
  terminal and immutable; it is not real spending, so it contributes zero to
  `effective_amount` (M2).

### Identity

The stable key is the bank's `entry_reference`. Use it, not
`transaction_id`, which changes between sessions at many banks.

When a bank sends no `entry_reference`, derive a fallback key by hashing
`(account_id, value_date, amount, currency, raw description)`. This is
imperfect — two identical coffees on the same day collide — so record which
strategy produced the key, and treat fallback-keyed rows as lower-confidence
during deduplication.

### Pending to booked

A pending transaction and its booked counterpart are **the same
Transaction** transitioning state, not two rows. Amount and description
routinely change slightly on settlement; that is expected, and updating them
does not violate immutability, which applies only after `booked`.

Pending transactions that neither settle nor reappear within a defined window
are dropped, not kept as ghosts.

### History window

The full transaction history is typically available only in the ~1 hour
following authorization. After that most banks serve roughly 90 days. The
initial sync after a new `Connection` must therefore be greedy and complete;
there is no second chance.

### Role and effective amount

`amount` is what the bank reported. It is not what the user actually spent.
Every `Transaction` carries a `role` that determines how much of it counts
as real personal spending:

| Role            | Effective amount                          |
| --------------- | ------------------------------------------ |
| `personal`      | full `amount` (default)                    |
| `transfer`      | zero — see `Transfer`                      |
| `advance`       | only the user's own share — see `Advance`  |
| `reimbursement` | zero — see `Reimbursement`                 |

`effective_amount` is derived, never stored as the source of truth. Every
dashboard, budget, and category total is computed from `effective_amount`.
Every raw balance reconciliation is computed from `amount`. Mixing the two
is the most likely source of numbers that look wrong to the user.

Role is set by the user or suggested by detection, never assumed silently.
An unreviewed suggestion does not change `effective_amount`.

---

## Transfer

Two transactions that represent the same money moving between two accounts
the user owns. Neither is income nor spending: both have an
`effective_amount` of zero.

A `Transfer` links exactly two transactions with opposite signs. It is
detected, not reported — no bank tells us a movement was internal.

**Detection** matches candidates on: opposite sign, same currency, amounts
equal or within a small tolerance (fees and FX alter them), different
accounts belonging to the same user, and dates within a short window
(settlement is not simultaneous).

Detection produces a **suggestion**, never a silent link. A wrongly detected
transfer erases a real expense from the user's totals, which is worse than
missing one.

**Confirming** a suggestion is the explicit user action that creates the
`Transfer`: it links exactly the two legs and sets both to `role=transfer`, so
their `effective_amount` becomes zero. Deleting the `Transfer` unlinks the legs
and reverts both to `personal`. A user may confirm any structurally valid pair —
different accounts, same currency, opposite signs, both still `personal` — even
one outside detection's amount tolerance or day window; those bounds constrain
automatic *suggestions*, not an explicit confirmation.

**Rejecting** a suggestion records a dismissal for that pair, so detection does
not propose it again (suggestions are recomputed on demand, so without this a
rejected pair would reappear). A dismissal is order-independent and rejecting the
same pair twice is idempotent.

**Half-transfers exist and are normal**: money moved to an account the user
has not connected. The outgoing leg has no counterpart and stays
`personal`. Do not treat an unmatched leg as an error.

---

## Event

A user-defined grouping of transactions that belong to the same real-world
occasion: a trip, a renovation, a wedding.

Fields: `name`, optional `start_date` and `end_date`, `status`
(`active` | `closed`).

A transaction belongs to at most one `Event`. Events do not replace
categories — they cut across them. "Turkey 2026" contains transport, food,
and accommodation, and the user wants both views: total spent on the trip,
and how that total splits by category.

Event totals use `effective_amount`. A €1.000 flight advanced for five
people contributes only the user's share to the trip total. This is the
whole point.

Events are the natural unit for the "advance and get paid back" pattern, but
the two are independent: an `Advance` can exist outside any `Event`, and an
`Event` can contain no advances.

Date range is a hint used to suggest membership, not a rule that assigns it.
A flight booked three months early belongs to the trip.

**Implementation note** (2026-08-21): membership is a nullable `event_id` on the
transaction row (at most one event per transaction), a db-only column managed by
the repository — an event is a reporting lens, so it deliberately does not appear
on the domain `Transaction` or extend `TransactionRole`. The event total is the
single **net** figure, derived by the pure `domain/events.py::event_total` over
members' `effective_amount`; the **by-category** breakdown waits on
categorization existing at all, and membership **suggestions** from the date
range are a later slice (the dates are stored as hints, nothing consumes them
yet) — both tracked in `tasks/backlog.md`. A mixed-currency event has no single
total (no FX in Traccio) and is refused.

---

## Advance

A transaction where the user paid for others and expects money back.

Fields:
- `transaction_id`: the outgoing transaction, whose `role` becomes `advance`
- `own_share`: integer cents the user actually owes. This is the part that
  counts as spending.
- `receivable`: derived as `amount - own_share`. What the user is owed.
- `outstanding`: derived as `receivable` minus reimbursements received.
- `participants`: optional list of plain names (free text, not `User`
  records) with an expected amount each. Enough to answer "who still owes
  me" without building a social graph.
- `status`: `open` | `settled` | `written_off`

`own_share` is declared by the user, not inferred. The app cannot know
whether the user paid for four people or five.

**Sign and storage (implementation note).** `own_share`, `receivable`, and
`outstanding` are stored and exposed as **positive magnitudes** (the euros the
user owes / is owed): `receivable = |amount| - own_share`, `outstanding =
receivable - Σ reimbursed`, validated `0 ≤ own_share ≤ |amount|`. Only
`effective_amount` needs a signed value; a single pure helper
(`domain/advances.py::advance_spending_share`) converts the magnitude to the
transaction's sign at that one boundary, so the `effective_amount` contract is
untouched. Creating an `Advance` sets the transaction's `role` to `advance`;
deleting it reverts to `personal`. Reimbursements and the `written_off`
transition are separate slices — until they land an advance is `open` with
`outstanding == receivable`.

**Advances that never settle are the normal case, not an edge case.** Money
gets paid back in cash, or in a round of drinks, or never. `written_off`
moves the outstanding amount into the user's spending, because at that point
it genuinely was spent. Without this, outstanding balances accumulate
forever and the user stops trusting the numbers.

An `Advance` is not a negative debt owed by the user. Traccio tracks money
the user is owed, not money the user owes. That is a separate feature and it
is not in scope.

---

## Reimbursement

An incoming transaction that pays back part of an `Advance`. Its
`effective_amount` is zero: it is not income, it reduces an outstanding
receivable.

One `Advance` has many `Reimbursements`. One `Reimbursement` belongs to
exactly one `Advance`.

**Amounts rarely match neatly.** A single incoming transfer may cover two
people's shares, or arrive rounded, or be split across two payments weeks
apart. Reimbursement amounts are therefore free: they are not validated
against a participant's expected share, only summed against `outstanding`.

Over-reimbursement is possible and must not crash anything: if the sum
exceeds `receivable`, the excess is flagged for the user rather than
silently absorbed.

**Matching** uses the debtor name from SEPA credit transfers, which is a
structured field and generally reliable, plus amount proximity to an open
participant share, plus recency of the advance. This produces a suggestion.
The user confirms. Never auto-link money.

Cash reimbursements exist and never appear in any API. The user must be able
to record one manually against an `Advance`.

**Storage and derivation (implementation note).** A `Reimbursement` stores its
`amount` as a positive magnitude (split into `amount` + `currency` like every
`Money`), an optional `transaction_id` (set for a linked incoming transaction,
`NULL` for a cash entry), and an optional free-text `note` — nothing else. The
advance's `outstanding`, `excess` (over-reimbursement) and its `settled` state
are **derived**, never stored: a single pure function
(`domain/advances.py::derive_advance`) folds `(receivable, Σ reimbursed,
written_off)` into `outstanding = max(0, receivable − Σ reimbursed)`, `excess =
max(0, Σ reimbursed − receivable)`, the derived `status`, and the signed
`spending_share` fed to `effective_amount`. Only `written_off` is stored on the
advance; `settled` is derived, so deleting a reimbursement reopens the advance
automatically. Linking a transaction sets its `role` to `reimbursement` (so its
`effective_amount` is zero); deleting the link reverts it to `personal`.
Automatic SEPA matching is a separate later slice that only suggests. See
ADR 0004.

---

## Category

What kind of spending a transaction represents (groceries, transport, rent).

Two layers, deliberately separate:
- `suggested_category_id`: assigned by the categorization engine. Overwritten
  freely on every re-run.
- `confirmed_category_id`: set by the user. **Never overwritten by any
  automated process.**

The effective category is `confirmed` if present, otherwise `suggested`.
Any code path that writes to `confirmed_category_id` without direct user
action is a bug.

Categories are user-scoped, seeded from a shared default set at signup. A
user renaming "Groceries" must not affect anyone else.

---

## Rule

A user-defined mapping from a transaction pattern to a `Category`, applied
during categorization. Rules run before the automatic engine and win over it,
but still write to `suggested_category_id` — they are automation, not a user
confirming an individual transaction.

---

## Sync

One attempt to pull fresh data for a `Connection`. Records what was
attempted, when, and what failed.

Two modes, and the distinction is not cosmetic:
- **User-present**: the user is actively waiting. Provider requests carry the
  PSU headers signalling this.
- **Background**: no user present. Many banks allow only ~4 background
  fetches per day per consent. Exceeding this gets the consent throttled, so
  background frequency is a hard constraint on product design, not a tuning
  parameter.

Syncs are idempotent: running the same sync twice produces no duplicate
transactions.

---

## Budget

A user-defined spending limit for a `Category` over a period. Computed from
effective categories, so confirming a category can retroactively change
whether a budget was exceeded. That is intended.

---

## Terms deliberately avoided

- **"Balance"** without qualification. Banks expose several (available,
  booked, cleared) and they disagree. Always name which one.
- **"Import"** for fetching from a bank. Use `sync`.
- **"Merchant"** as a stored entity. For now it is a parsed hint on the
  transaction, not a first-class record.
- **"Split"** as a verb on a transaction. Traccio does not divide a bill
  among people the way Splitwise does; it records what the user is owed
  against a real bank transaction. The distinction matters: there is no
  shared ledger and no other users involved.