# 0026 — Advances: a cross-advance receivables summary, name-keyed

Status: accepted
Date: 2026-09-07

## Context

An `Advance` (ADR 0002, `docs/domain.md` §Advance) records that the user
paid for others on one outgoing transaction and is owed money back. Each
advance carries its own `own_share`, its own derived `outstanding`, and its
own `Participant` rows; a `Reimbursement` may be attributed to one
participant (ADR 0012).

`GET /advances` returned a bare list. Everything it exposed was *per
advance*. The first question the feature gets in daily use is the opposite
shape: **"who owes me money, and how much in total?"** Answering it means
adding up participants and outstandings *across* advances — and there is no
place that belongs on the client (`client/CLAUDE.md`: "the backend owns
every derived value").

Two facts make this awkward:

1. **There is no `Person` entity.** A `Participant` is minted per advance
   (`routers/advances.py`), so "Marco" on two advances is two unrelated
   UUIDs, joinable only on the `name` string.
2. **Advances can span currencies.** ADR 0020's manual accounts accept any
   currency, and an advance's currency is its transaction's.

## Decision

**1. The summary is derived server-side and rides in the existing
envelope.** `GET /advances` now returns
`{ advances: [...], summary: { by_person: [...], totals: [...] } }`. The
roll-ups are pure functions in `domain/advances.py` — `summarize_people`
and `total_receivable` — over the same `AdvanceState` /
`ParticipantState` values the row projection already derives. No new query:
the two whole-user reimbursement aggregates (ADR 0004 / ADR 0012) are
unchanged, and the per-advance derivation is computed once and shared
between a row and the summary.

**2. People are grouped by a normalized name key, not an entity.**
`person_key(name) = " ".join(name.split()).casefold()` — internal
whitespace collapsed, surrounding whitespace stripped, case folded. So
`"Marco"`, `" marco "` and `"MARCO"` roll up together; a genuine typo
(`"Mardo"`) stays separate and **cannot be merged after the fact**. The
grouping key is `(person_key, currency)`; the display name is the first
spelling seen, whitespace-collapsed. This is the accepted cost of not
building a social graph (`docs/domain.md` already says free-text names are
"enough to answer 'who still owes me'"). A real `Person` entity with
merge/rename is a deliberate non-goal now, filed in `tasks/backlog.md` for
if the name key proves insufficient.

**3. One row per currency; no FX conversion.** `by_person` and `totals`
each yield one entry per currency. Converting to a base currency would pull
in ADR 0021's rate resolver — a second, disputable source of truth for a
number, and a dependency for a case (multi-currency advances for one
person) that does not exist yet. `total_receivable` returns a list keyed by
currency, matching `GET /dashboard/summary`'s per-currency discipline
(ADR 0007). Filed in `tasks/backlog.md` for when it is actually needed.

**4. The per-person sum may fall short of the per-currency total, by
design.** A reimbursement with `participant_id = None` lowers the advance's
`outstanding` but no participant's (the rule `ParticipantState` already
follows, ADR 0012). `total_receivable` sums advance-level `outstanding`;
`summarize_people` sums participant-level. When they diverge, the total is
authoritative and the client shows an explanatory line rather than hiding
the gap.

**5. Written-off advances contribute zero to the total.** `derive_advance`
keeps a written-off advance's `outstanding` populated (the write-off moves
that amount into spending, not to zero), so `total_receivable` excludes
`status == written_off` explicitly. The user chose to stop expecting that
money.

**6. The list gains a `status` query parameter; the summary ignores it.**
`GET /advances?status=open|settled|written_off` narrows the returned
`advances`, applied in Python *after* deriving every advance (only
`written_off` is stored; `open`/`settled` are derived). `summary` is always
computed over the full set, so the totals do not move when the client
filters the visible rows.

## Consequences

- **Client is a pure renderer.** New hand-written models
  (`PersonSummaryResponse`, `ReceivableTotalResponse`,
  `AdvancesSummaryResponse`); `APIClient.advances(status:)` returns the
  whole envelope instead of unwrapping it. A new "Anticipi" screen under
  Impostazioni (ADR 0009) renders the summary and the list; it computes
  nothing.
- **`AdvanceResponse` still carries no transaction description/date**, so
  the new screen resolves each advance's transaction with a per-id fetch.
  The zero-query fix (add `description` + `booked_at` to `AdvanceResponse`,
  which the router already holds) is filed in `tasks/backlog.md`, not done
  here.
- **Name collisions are silent.** Two different people both entered as
  "Marco" in the same currency roll into one row. Accepted; the fix is a
  `Person` entity, deferred.
- `GET /advances` does one extra pass over the already-loaded advances to
  build the summary — O(advances × participants), no I/O.

## Alternatives considered

- **A separate `GET /advances/summary` endpoint.** Rejected: the list page
  already loads everything the summary needs, and a second endpoint means a
  second round trip and a second set of the same aggregate queries. The
  envelope "leaves room for metadata later" — this is that.
- **Client-side summation.** Rejected outright by `client/CLAUDE.md` — a
  derived number is a backend gap, not a client feature.
- **A `Person` entity now** (table scoped by `user_id`, participants
  reference it, merge/rename UI). The correct long-term model, but a
  migration + an ADR + management UI — a project of its own, not a rider on
  this one. Deferred to `tasks/backlog.md`.
- **FX-converted grand total** reusing ADR 0021's resolver. Deferred: no
  multi-currency-per-person case exists yet, and ADR 0021 itself is opt-in
  and dashboard-only.

## 2026-09-09 note: `person_key` on the wire, rows self-sufficient

Two follow-ups this ADR filed are done. `AdvanceResponse` now carries the
transaction's `description` / `display_description` / `booked_at` (populated
from the transaction the router already holds — no extra query), so the
Anticipi list no longer fans out one `GET /transactions/{id}` per row; a row
navigates through a `TransactionDetailLoader` that resolves the transaction
only when opened. `ParticipantResponse` and `PersonSummaryResponse` expose
the server-computed `person_key` (`domain/advances.person_key`), so the
client — the new `PersonDetailView` drill-down — ties a participant to its
roll-up row by an exact string compare rather than re-implementing the
normalization. The name-key grouping stays a §2 backend concern; the client
only matches on the key it is handed.

## 2026-09-09 note: the tracking-start floor applies

`GET /advances` originally computed `summary` over every advance regardless of
the user's `tracking_start_date` (ADR 0024). It now excludes an advance whose
transaction falls before that floor — from `advances` and from `summary`
alike — so the receivables roll-up counts the same movements the dashboard
does. Implementation and rationale are in ADR 0024's 2026-09-09 revision. §6
still holds: `status` narrows only the visible rows; the floor narrows both,
because a movement the user cannot see anywhere else should not silently prop
up a "da ricevere" figure.
