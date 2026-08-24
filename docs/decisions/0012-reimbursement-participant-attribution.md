# 0012 — Reimbursement participant attribution

Status: accepted
Date: 2026-08-24

## Context

The M3 design canvas (`docs/design/canvas/TransactionDetail.dc.html`) mocks a
per-participant reimbursement status on the advance detail screen —
"Marco — Rimborsato" / "Giulia — In attesa" — but nothing behind it could
support it honestly: a `Reimbursement` (ADR 0004) links only to the advance
as a whole, never to a specific `Participant`. `tasks/backlog.md` carried this
as an open modelling question since the client slice that first tried to
build the screen: "does a cash reimbursement get attributed to a participant
at entry time?"

A second, smaller gap sat underneath it: `Participant` had no identity at all
at the domain level. `AdvanceParticipantRow` always had a database `id`, but
`db/mappers.py::participant_to_row` minted a fresh one on every write and
`row_to_participant` discarded it on every read — so even if a reimbursement
*wanted* to reference "this specific participant", nothing stable existed to
reference. This ADR settles both: give `Participant` a real identity, and let
a `Reimbursement` optionally attribute itself to one.

## Decision

**1. `Participant` gets a stable `id`, minted once and preserved on every read.**

`domain/models.py::Participant.id` uses the same `default_factory=uuid4`
pattern every other entity's `id` already uses. The mapper change is the
whole fix: `participant_to_row` now writes `participant.id` instead of
generating a new one, and `row_to_participant` now reads `row.id` instead of
dropping it. `AdvanceParticipantRow.id` needed no migration — it already
existed; only the domain round-trip was throwing it away.

**2. Attribution is explicit, at entry time, never inferred.**

`Reimbursement.participant_id` is an optional field the user sets when
recording a reimbursement (`POST /advances/{id}/reimbursements`). Nothing
guesses it from a name or an amount — consistent with ADR 0004's "explicit
user action" framing and the project's "detection never mutates" rule.
`POST` validates the id belongs to the advance's own participants (`404
unknown_participant`), the same treatment an unknown linked transaction id
already gets.

**3. A reimbursement attributes to at most one participant.**

No join table. `docs/domain.md` already notes that "a single incoming
transfer may cover two people's shares" — that case is handled by recording
**two** reimbursements, one per person, not by letting one reimbursement
point at many participants. This keeps the common case (one payment, one
person, or unattributed cash — still fully supported, `participant_id =
NULL`) simple, and matches how a split is already handled today when it
doesn't need per-participant attribution at all.

**4. Per-participant state is derived, never stored — same discipline as the
advance's own `outstanding`/`excess`/`settled` (ADR 0004).**

A new pure function, `domain/advances.py::derive_participant_states`, takes
each participant and an already-aggregated `participant_id -> reimbursed`
map and produces `outstanding = max(0, expected − reimbursed)`, `excess =
max(0, reimbursed − expected)`, and `status` (`settled` once `reimbursed ≥
expected`, mirroring `AdvanceState`'s own boundary). Reimbursement amounts
stay free at the participant level too — never validated against
`expected_amount`, same looseness ADR 0004 already established at the advance
level. `group_reimbursements_by_participant` is the sibling pure function
that produces the aggregated map from a raw reimbursement list.

**5. Never a second query per advance.**

`derive_participant_states` takes an already-aggregated map rather than the
raw reimbursement list, so it works identically whether the caller has one
advance's reimbursements already loaded in memory (`GET /advances/{id}`,
write-off, reopen — refactored into one shared `_reimbursement_derivations`
helper so the list is loaded exactly once per request) or a whole page's
worth via one new grouped query, `sum_reimbursements_by_participant`, the
per-participant sibling of ADR 0004's `sum_reimbursements_by_advance`.

## Consequences

- `ParticipantSchema` splits into `ParticipantRequest` (unchanged: name +
  expected amount, no id — the caller cannot know it yet) and
  `ParticipantResponse` (id + the derived state) — the Swift client already
  had this split (`ParticipantRequest.swift`/`ParticipantResponse.swift`),
  anticipating exactly this; the backend now matches it.
- `AdvanceResponse.from_domain` takes `participant_states` as a required
  keyword argument, computed by the caller — the schema layer projects, it
  does not derive.
- The client's `ForEach(advance.participants.enumerated(), id: \.offset)`
  workaround (there was no other stable key) becomes a plain
  `ForEach(advance.participants)` now that `ParticipantResponse` is
  `Identifiable`.
- `AddReimbursementSheet` gains a participant picker; its `onCreate` callback
  became a `ReimbursementDraft` value type instead of a growing positional
  tuple, once it needed to carry two same-typed `UUID?` fields
  (`participantID`, `transactionID`) that a call site could otherwise
  transpose without the compiler noticing.

## Alternatives considered

- **Derive attribution greedily instead of storing it** (mark participants
  settled in order as reimbursements arrive, cheapest first). Rejected: it
  would invent an attribution the user never actually stated, and would still
  need `Participant.id` to render a stable list — it solves nothing the
  stored, explicit approach doesn't already solve better.
- **A join table for reimbursement-to-participant splits.** Rejected as
  premature: no real case has needed one payment split across participants in
  the same reimbursement; two reimbursements already cover it, and a join
  table is strictly more machinery for a case that hasn't come up.

## Revisit when

- A real split reimbursement (one payment, multiple participants) turns out
  to be common enough in practice that recording it as two rows is
  genuinely annoying — the join-table alternative above becomes worth
  reconsidering then, not before.
