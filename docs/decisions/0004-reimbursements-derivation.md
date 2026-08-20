# 0004 — Reimbursements: derived state, stored write-off

Status: accepted
Date: 2026-08-21

## Context

Advances shipped (M2) able to record that the user paid for others and is owed
money back, but with no way to record the money coming back: an advance was
always `open` with `outstanding == receivable`, and the `settled`/`written_off`
lifecycle states existed unused. The seams were left in place —
`domain/advances.py::outstanding(receivable, reimbursed)`, the `reimbursement`
transaction role (already zero in `effective_amount`), and the `AdvanceStatus`
members — to be filled by this slice.

Adding reimbursements raises three modelling questions that this ADR settles.
They matter because `effective_amount` is the single derived value every
dashboard total flows from (`docs/architecture.md`), so where the reimbursement
arithmetic lives, and whether lifecycle state is stored or derived, determines
whether the numbers can silently drift.

## Decision

**1. `settled` is derived, never stored. Only `written_off` is stored.**

An advance's stored `status` holds `open` or `written_off`. Whether it is
`settled` is derived from the reimbursements: `Σ reimbursed ≥ receivable ⇒
settled`. Deleting a reimbursement therefore reopens the advance automatically;
there is no stored flag that can contradict the reimbursement rows. This follows
the house rule that `outstanding` is derived and never stored — `settled` is a
fact about the same sum, so it is derived from the same source.

**2. The write-off feeds `effective_amount` through one pure function.**

Writing off an advance moves the still-outstanding amount into the user's
spending (it genuinely was spent). That changes the transaction's
`effective_amount` from `own_share` to `own_share + outstanding`. Rather than
teach `effective_amount` about advances, a single pure function
`domain/advances.py::derive_advance(...)` computes the whole advance state —
`receivable`, `outstanding` (clamped at zero), `excess`, the derived `status`,
and the **signed** `spending_share` — and the transaction projection feeds that
share into the unchanged `effective_amount`. The "one pure derivation" invariant
holds: `effective_amount` is still the only place the role rule lives, and the
advance-specific arithmetic is still the only place the write-off rule lives.

**3. Over-reimbursement is flagged, never absorbed.**

`outstanding = max(0, receivable − reimbursed)` and `excess = max(0, reimbursed
− receivable)`. When more comes back than was owed, `outstanding` clamps to zero
and the surplus is surfaced as `excess` on the advance, rather than silently
swallowed or crashing.

**4. A reimbursement is a manual cash entry or an explicit transaction link.**

A reimbursement either links an existing incoming transaction (whose role
becomes `reimbursement`) or is a manual cash entry with no transaction. Both are
explicit user actions. Automatic SEPA-debtor matching is a separate, later slice
that will only *suggest* — consistent with "detection never mutates". Amounts
are free: they are summed against the receivable, never validated against a
participant's expected share.

## Consequences

- Advance lifecycle needs no state machine: the derived status is a pure
  function of `(receivable, Σ reimbursed, written_off)`, recomputed on read.
- The transaction listing must load the reimbursed total per advance to derive
  each advanced transaction's spending share; done in one aggregate query
  (`sum_reimbursements_by_advance`), not per row.
- Write-off is reversible (`reopen`) precisely because only that one bit is
  stored; everything else re-derives.
- The client still computes nothing: it renders `outstanding`, `excess`, and the
  derived `status` returned by the backend.

## Alternatives considered

- **Store the full `status` (including `settled`) and transition it on each
  reimbursement write.** Rejected: a stored `settled` can drift from the
  reimbursement rows (e.g. after a delete), reintroducing exactly the
  "numbers look wrong" class of bug the derived-value rule exists to prevent.
- **Extend `effective_amount` to take the advance and reimbursements directly.**
  Rejected: it would pull advance/reimbursement concepts into the one function
  that must stay a small, role-driven derivation, and blur the single
  responsibility. `derive_advance` keeps the advance arithmetic in `advances.py`.

## Revisit when

- Automatic SEPA reimbursement matching is built (the next M2 slice) — it plugs
  into this model as a suggestion layer, and should not need to change any of
  the decisions above.
