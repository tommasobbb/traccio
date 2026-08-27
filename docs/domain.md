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
- `status`: `pending` | `active` | `expired` | `revoked` | `error` — the last
  status the *provider* reported. It does not by itself say whether the
  180-day consent window has since elapsed; see "Expiry" below.
- `country`: ISO 3166-1 alpha-2 country of the institution, kept alongside
  `institution_name` so a later re-authorization can call the provider again
  without asking the user to pick the bank a second time.
- `expires_at`: consent expiry, as reported by the provider. For most banks
  the maximum session lifetime is 180 days, after which the user must
  re-authorize.
- Credentials/tokens are **encrypted at rest**, never logged, never returned
  by any API endpoint, not even to the owning user.

A `Connection` is not an `Account`. One consent typically exposes several
accounts.

**Expiry is a first-class product concern, not an error case.** `status` alone
is not the truth about whether a consent still works — it is only ever
updated by the provider (activation, revocation, an error). The *actual*,
time-aware state is `ConsentState`, derived by `domain/consent.py::consent_state`
by re-reading a stored `active` status against `expires_at` and the current
time: `pending` / `revoked` / `error` / a provider-reported `expired` pass
through unchanged; a stored `active` becomes `expiring_soon` inside the
warning window (`Settings.consent_warning_window_days`, default 14 days) or
`expired` once `expires_at` has passed. This is deliberately derived, never
stored — the same reasoning as `Advance.settled` (see `Reimbursement`
below): a stored expiry flag needs a background job to stay true and is wrong
between runs, while deriving it from `now` is correct the instant it is read.
`GET /connections` returns both `status` and `consent_state`; the client
renders `consent_state`.

**Re-authorizing reuses the same `Connection` row**, rather than creating a
new one: `POST /connections/{id}/reauthorize` re-arms it with a fresh
anti-CSRF `state` and starts a new SCA authorization for the same institution
and country; completing the usual callback activates that same row in place.
Its accounts, and their transaction history, stay attached — the provider
documents the account-level stable identity as holding across
re-authorizations (`docs/openbanking.md`). A connection created before
`country` was recorded (`None`) cannot be re-authorized this way; the client
falls back to a fresh `POST /connections`.

Syncing a connection whose derived `consent_state` is `expired` is refused
(`409`) before the provider is ever called, rather than surfacing whatever
opaque error the provider returns for a dead session.

---

## Account

A single balance-bearing account: usually one exposed by a bank — a current
account, a savings account, a card account, or a currency-agnostic wallet
(e.g. PayPal) — or a **manual** one the user creates and maintains by hand
(ADR 0020), such as a cash float or an investment pass-through.

`kind`: `current` | `savings` | `card` | `wallet` | `cash`

`source`: `synced` | `manual` — **derived, never stored**
(`domain/accounts.py::account_source`). A synced account is backed by a
`Connection`; a manual account has `connection_id` and `identification_hash`
both `null`. The two are a validated either/or: `Account` refuses to construct
with one set and not the other. `kind` is a separate axis — a manual account
still has a real kind (`cash` for "Contanti", `wallet` or `current` for an
"Investimenti" pass-through; there is deliberately no `investment` kind, as
Traccio does not do portfolio tracking — see `ROADMAP.md`).

**A sync can never touch a manual account.** `upsert_account` matches on
`(user_id, identification_hash)`, and `NULL != NULL` in SQL; `services/sync.py`
also only ever iterates the provider's own account list. A manual account and
its transactions are created, edited, and deleted only through
`POST /accounts`, `DELETE /accounts/{id}`, `POST /transactions`,
`POST /transactions/{id}/edit`, and `DELETE /transactions/{id}` — all of which
refuse to act on a synced account or its rows. `DELETE /accounts/{id}` refuses
a non-empty account (`409 account_not_empty`); its movements are deleted
first.

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
consents. Match synced accounts across `Connections` using a derived
`identification_hash`, not the provider's account ID. A manual account has no
`identification_hash` (it is `null`) and needs none — nothing re-exposes it.

**Display name, colour, and icon are user-owned appearance, separate from the
provider's own name** (ADR 0017). `name` is the bank's product name
(`details["product"]`), overwritten on every sync — there is no way for it to
carry a user's preference. `alias`, `color`, and `icon` are set only by
`POST /accounts/{id}/rename` and `POST /accounts/{id}/appearance`, and
`upsert_account` never touches them on re-sync. `display_name` (`alias` if
set, else `name`, else `null`) is resolved once, server-side, in
`domain/accounts.py::display_name` — the single place this fallback exists.
`color`/`icon` are a fixed vocabulary (`ColorToken`/`AccountIcon`), not free
hex or SF Symbol strings — see ADR 0017 for why.

---

## Transaction

A single movement on an `Account`.

**Editability follows the row's origin, not its `status`** (ADR 0020). A
movement on a **synced** account is immutable — the bank is the source of
truth, and corrections arrive as new transactions, never as edits. A movement
on a **manual** account is the user's own: it is always `booked` (there is no
pending lifecycle without a bank), it is keyed by its own id
(`key_strategy=manual`), and it can be edited (`POST /transactions/{id}/edit`,
amount / currency / value date / description) or deleted
(`DELETE /transactions/{id}`). A delete is refused (`409 transaction_in_use`)
while the row is a leg of a transfer, advance, or reimbursement.

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
are dropped, not kept as ghosts. Implemented by
`db/repositories.py::prune_stale_pending_transactions`, called from the
explicit `POST /transactions/prune-pending` (mirroring `POST /rules/apply`'s
precedent — not wired into sync until a background scheduler exists to make
that worth the added write path). The "window" is measured against
`last_synced_at`, a sync-process timestamp stamped on every `Transaction` row
by every sync that observes it (insert, a pending refresh, or a terminal row
re-seen unchanged) — not against `booked_at`/`value_date`, which are both
nullable and, per `docs/openbanking.md`'s Revolut findings, not reliably
correlated with "still pending" in the first place. A row that has never been
re-stamped by a sync (predates the column) is treated as not yet eligible,
never as eligible by default. A pending row the user has already acted on —
linked as a transfer/advance/reimbursement (any `role` other than `personal`),
assigned to an `Event`, or carrying a `confirmed_category_id` — is never
pruned, even once stale; a suggested (not confirmed) category is not a
commitment and does not protect a row.

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

The client surfaces the explicit path as a **pick-two selection mode** in
Movimenti (2026-08-27): the user selects any two rows and confirms them
directly through `POST /transfers/confirm`, independent of whether detection
ever suggested them — the same endpoint, no suggestion required.

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
members' `effective_amount`. Categorization now exists (see §Category,
2026-08-21), so the **by-category** breakdown is unblocked in principle, but
extending `event_total` to group members by category is still its own later
slice, not shipped here. Membership **suggestions** from the date range are
also a later slice (the dates are stored as hints, nothing consumes them yet)
— both tracked in `tasks/backlog.md`. A mixed-currency event has no single
total (no FX in Traccio) and is refused.

**Implementation note** (2026-08-24): the client had no surface for any of
this until now — a full backend with zero callers. Shipped end to end: one
new endpoint, `GET /events/{id}/transactions`, reuses the existing
`list_event_members` repository read (previously only consumed internally by
`_event_response`) to expose an event's member transactions, unpaginated
(the member set is bounded, unlike `GET /transactions`'s pool). The Eventi
screen (`App/Sources/Events/`, reached from Impostazioni per ADR 0009) lists
events, creates one, and on its detail screen shows the net total and
members, assigns/unassigns transactions, and closes/reopens or deletes the
event. `start_date`/`end_date` introduced a new client-side type,
`TraccioCore.CalendarDate` — the first date-only (`yyyy-MM-dd`) field in the
API, deliberately not folded into the shared timestamp decoder.

**Implementation note** (2026-08-24): `TransactionResponse.event_id` now
exposes membership on the transaction read model, and `GET /transactions`
gained `event_id`/`category_id`/`uncategorized` filters (the last two on the
**effective** category, `coalesce(confirmed_category_id, suggested_category_id)`;
combining `category_id` with `uncategorized` is a `422
conflicting_category_filter`). This is a **display join, not a domain
change**: `event_id` is resolved separately in `api/routers/transactions.py`
(`db/repositories.py::get_transaction_event_id` /
`event_ids_for_transactions`) and passed into
`TransactionResponse.from_domain` as a keyword — the domain `Transaction`
still carries no `event_id`, unchanged from the 2026-08-21 note above; the
same pattern the dashboard category breakdown uses to resolve a category
name. No `event_name` is returned — the client resolves it from `GET
/events`, same as it already does for category names. This closes the gap
that made the advance-detail event chip and `AddEventMembersSheet`'s
candidate list unable to tell which event (if any) a transaction already
belonged to; both now filter on `TransactionResponse.eventID` instead of
discovering the conflict only via the backend's `409`. Movimenti's
account/category filter chips (`docs/design/canvas/Transactions.dc.html`)
are the client surface for the same two query parameters — filtering is
always server-side, never applied to an already-fetched page
(`TraccioCore.TransactionFilter`).

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

**Participant identity (implementation note, ADR 0012).** Each `Participant`
carries a stable `id`, minted once at creation and preserved on every read —
what a `Reimbursement` attributes itself to (see §Reimbursement). Before ADR
0012 this `id` was minted fresh on every database read and thrown away, so
nothing could reference "this specific participant" across a request
boundary; it is otherwise still a free-text name, not a `User` record.

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

**Participant attribution (ADR 0012)** is a separate, optional dimension: the
user may explicitly attribute one `Reimbursement` to one `Participant` at
entry time, which derives that participant's own reimbursed/outstanding/
status the same way the advance's own totals are derived — never validated
against that participant's expected share either, same looseness as the
advance-level amount. A `Reimbursement` attributes to **at most one**
participant: a single transfer that really did cover two people's shares is
recorded as two separate reimbursements, one per person, not modeled as a
join table — deliberately, to keep the common case (one payment, one person,
or unattributed cash) simple. An unattributed reimbursement (the only option
before ADR 0012, still fully supported) counts toward the advance's total but
toward no participant's.

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
`NULL` for a cash entry), an optional `participant_id` (ADR 0012, see above —
`NULL` for an unattributed one), and an optional free-text `note`. The
advance's `outstanding`, `excess` (over-reimbursement) and its `settled` state
are **derived**, never stored: a single pure function
(`domain/advances.py::derive_advance`) folds `(receivable, Σ reimbursed,
written_off)` into `outstanding = max(0, receivable − Σ reimbursed)`, `excess =
max(0, Σ reimbursed − receivable)`, the derived `status`, and the signed
`spending_share` fed to `effective_amount`. Only `written_off` is stored on the
advance; `settled` is derived, so deleting a reimbursement reopens the advance
automatically. Linking a transaction sets its `role` to `reimbursement` (so its
`effective_amount` is zero); deleting the link reverts it to `personal`.
Each participant's own `reimbursed`/`outstanding`/`excess`/`status` is derived
the same way, one level down, by the sibling pure function
`domain/advances.py::derive_participant_states` — grouping reimbursements by
`participant_id` first (`group_reimbursements_by_participant`), never touching
the advance-level arithmetic above. Automatic SEPA matching is a separate
later slice that only suggests. See ADR 0004 and ADR 0012.

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

**Implementation note** (2026-08-21): unlike `Event`'s `event_id`, both
`suggested_category_id` and `confirmed_category_id` **do** live on the domain
`Transaction` — a category is an attribute of the movement, like `role`, not a
cross-transaction grouping, and every derived total downstream (a dashboard, a
budget, the event-by-category breakdown) is a function of
`(effective_amount, effective_category)`. The asymmetry that protects
"never overwritten by any automated process" is structural, not just
discipline: `db/mappers.py::row_to_transaction` reads both ids,
`transaction_to_row` writes neither, so a sync has no path to touch either
column. `db/repositories.py::set_confirmed_category` is the **only** writer of
`confirmed_category_id` in the codebase, called only from the two
`POST`/`DELETE /transactions/{id}/category` endpoints — an explicit user
action every time. `domain/categories.py::effective_category` is the one place
the fallback rule is evaluated. There is no `set_suggested_category` yet; the
categorization engine that would call it is a later slice
(`tasks/backlog.md`). Seeding happens at `POST /categories/defaults`
(idempotent: only when the user has zero categories) rather than at signup,
since there is no signup flow before M4. Deleting a category refuses (`409`)
if it is `confirmed` on any transaction — nulling user-confirmed data as a
side effect of deleting a different entity would itself be the automated
write the rule forbids — but clears any `suggested` references, since that
layer is disposable by design.

**Hierarchy, colour, and icon** (ADR 0018, ADR 0017, 2026-08-25): a category
nests in a **strict two-level hierarchy** — `parent_id` is `None` (a root) or
names a root; a category whose own `parent_id` is set can never itself be a
parent. `domain/categories.py::validate_parent` is the one place depth is
checked (the schema cannot portably express "at most two levels"). Deleting a
category refuses (`409 category_has_children`, checked before the
confirmation-in-use refusal above) when it has children — the same posture as
the confirmation refusal: silently orphaning or cascading would be a mutation
the user never asked for. Reparenting is its own action,
`POST /categories/{id}/move`, so reorganizing does not require delete-and-
recreate (which the confirmation refusal would block anyway for exactly the
categories worth reorganizing).

Every category carries a `color` (`PaletteColor`, never `None` — every
creation path resolves one, defaulting to the parent's own colour for a new
child or to `slate` for a root) and an optional `icon`. Both are fixed,
shared vocabularies, not free hex/SF Symbol strings — see ADR 0017.

Uniqueness on `(user_id, name)` stays **global**, not per parent: two
children under different roots cannot share a name (you write "Bollette
casa" / "Bollette auto", not two "Bollette"). A per-parent constraint was
considered and rejected — `NULL` compares distinct to itself on PostgreSQL, so
a `(user_id, parent_id, name)` constraint would let two same-named *roots*
through, and every client surface (a picker, a filter chip, a rule) renders a
category by bare name, where two identically-named children would be
indistinguishable anyway. See ADR 0018 for the full argument.

---

## Rule

A user-defined mapping from a transaction pattern to a `Category`, applied
during categorization. Rules run before the automatic engine and win over it,
but still write to `suggested_category_id` — they are automation, not a user
confirming an individual transaction.

A rule may target a root **or a child** category (ADR 0018) — `category_id` is
just a foreign key, and the service that applies rules has no notion of the
hierarchy at all. Precision is the entire point of a child category
(`"AMAZON PRIME"` → `Subscriptions › Streaming` rather than the whole of
`Subscriptions`), so no special case exists for it.

**Implementation note** (2026-08-21): a rule matches on `Transaction.description`
— the raw bank text — never `display_description`, since no code path
populates that field today; matching against it would silently change
behaviour the day cleanup lands. Matching is one of three case-insensitive
predicates (`RuleMatchKind`): `contains`, `starts_with`, `equals`. Deliberately
no regex and no amount/account conditions — the rules engine is meant to stay
"cheap and its accuracy... knowable" (`tasks/ROADMAP.md`), not a second
pattern language to maintain.

When two rules match the same transaction, the **longer `pattern` wins** (ties
break by `created_at` ascending, then `id`) — `"AMAZON PRIME"` beats
`"AMAZON"` because it is the more specific match. There is deliberately no
stored `priority`: the user raises a rule's precedence by sharpening its
pattern, not by reordering a list. `services/categorization.py::evaluation_order`
is the one place this ordering is computed, shared by `GET /rules` (so what
the user sees is the order rules actually fire in) and by rule application.

`POST /rules/apply` is the only path that writes `suggested_category_id`, and
it is a **full, idempotent recompute**: every one of the user's transactions is
re-evaluated from scratch, so a transaction whose matching rule was deleted
since the last run has its stale suggestion cleared to `None`, not left
untouched. A transaction with a `confirmed_category_id` still receives a
suggestion underneath it — the suggestion layer is a pure function of
`(rules, transactions)` and does not know about confirmation;
`effective_category` is what makes the confirmed value win. Deleting a
`Category` also deletes every `Rule` targeting it (see
`db/repositories.py::delete_rules_for_category`) — a rule pointing at a
category that no longer exists is broken, and the automation layer is
disposable by the same reasoning already applied to a category's own
`suggested_category_id` references. Applying rules is never wired into sync;
it stays an explicit user action, like transfer detection.

---

## Sync

One attempt to pull fresh data for a `Connection`, modeled as `SyncRun`
(`domain/models.py`, ADR 0010). Records what was attempted, when, and what
failed — including a skip, which is what makes the background fetch budget
below verifiable rather than trusted on faith.

Two modes (`SyncTrigger`), and the distinction is not cosmetic:
- **User-present**: the user is actively waiting. Provider requests carry the
  PSU headers signalling this (not yet wired to the adapter — see
  `tasks/backlog.md`).
- **Background**: no user present, run by `services/scheduler.py` on a timer.
  Many banks allow only ~4 background fetches per day per consent. Exceeding
  this gets the consent throttled, so background frequency is a hard
  constraint on product design, not a tuning parameter — read here as ~4
  `SyncRun`s per rolling 24h per connection
  (`domain/sync_schedule.py::sync_decision`), since one run already makes
  several provider calls internally.

Whether a connection is *due* for a background sync right now is derived
fresh on every scheduler tick — never stored — from the connection's
consent state, its recent `SyncRun` history, and the clock: the same
derived-not-stored reasoning as `ConsentState` (ADR 0006).

Syncs are idempotent: running the same sync twice produces no duplicate
transactions. The very first sync on a connection is greedy (the short
post-authorization window is the only chance at full history); every sync
after that requests only since the last one, with a small overlap to absorb
retroactively dated entries.

---

## Dashboard

The read-side answer to "how much did I actually spend and receive": a
summary derived from `effective_amount` alone (ADR 0007), never raw `amount`
— the same invariant every other derived value follows
(`docs/architecture.md`), made user-visible here as a headline number for the
first time. A transfer between the user's own accounts does not inflate
spending; an advance counts only the user's declared share; a reimbursement
is not income. Nothing is stored — recomputed on every read, like an event's
total.

One summary per currency present in the period, never summed across them —
there is no FX in Traccio. Within a currency, `spending` and `income` are
**positive magnitudes** (same convention as `Advance.receivable`/
`outstanding`) and `net` is the one signed figure. A transaction whose
`effective_amount` is zero (a transfer leg, a reimbursement, a rejected
movement) contributes to neither total, but is still counted.

The period is measured on the same `coalesce(booked_at, value_date)`
expression the transaction read-back endpoints already order by, and is
**half-open** (`start` inclusive, `end` exclusive) so consecutive periods
never overlap. A transaction with neither date set is excluded by any bound
on that side, and included only when the period is fully open. Pending
transactions are included — money already committed is not a maybe.

**Category breakdown** (2026-08-24): each currency's totals additionally
partition by `effective_category` — one `CategorySummary` per category
present, plus a fixed entry for `category_id = None` covering every
transaction with no category at all (a real, counted bucket, never omitted).
Same conventions as the currency level: `spending`/`income` are positive
magnitudes, a zero-`effective_amount` transaction is counted but contributes
to neither, and a category never spans currencies — the partition sums
exactly to its own currency's totals, never a separate cross-currency figure.
Sorted by `spending` descending, then `income` descending, then `category_id`
for a deterministic order.

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