# 0009 — Client navigation: a fourth "Impostazioni" tab

Status: accepted
Date: 2026-08-24

## Context

The client shipped M3's design direction (ADR 0008) around a three-tab shell
— Panoramica, Movimenti, Conti — and the design canvas
(`docs/design/canvas/`) mocks exactly those three tabs plus one pushed detail
screen. Every M3 slice since has found its home inside one of the three: a
pushed screen from a toolbar item (Trasferimenti from Movimenti) or a sheet
(the advance write loop).

That stopped working with the categorization-rules client slice. Its natural
home is a screen the user visits occasionally, not one of the three daily
surfaces, and it is not the last such screen: Eventi (an entire M2 backend —
CRUD, membership, derived totals — with zero client surface today) has the
same shape, and `tasks/backlog.md` already lists biometric lock and
backup/export as pending, both settings-shaped rather than daily-use-shaped.
Squatting Movimenti's toolbar for all of these would turn one tab's toolbar
into a junk drawer; squatting Conti's reserved "+" affordance (already mocked
for a future institution picker) would be worse.

This is exactly the situation ADR 0008's "Revisit when" warned about: a
change that would let SwiftUI and the design canvas drift apart needs a
decision recorded here, not a screen added silently.

## Decision

**Add a fourth tab, "Impostazioni"**, as the container for every
settings-shaped screen the client has or will have. Its first and, for now,
only entry is "Categorie e regole" (`CategorizationView`, reached via a
`NavigationLink`), pushed rather than a fifth tab of its own.

The tab itself is built the same way every other screen is — a `ScrollView`
of `Card`s with a row idiom matching `AccountsView`'s account rows, not a
stock `List` — so it does not reintroduce the plain-row look ADR 0008
replaced. `SwiftUI`'s `List` was considered and rejected for exactly that
reason: a settings screen is not exempt from the custom design system just
because stock `Form`/`List` styling is the platform default for one.

**What does not change:**

- The three daily-use tabs (Panoramica, Movimenti, Conti) keep their exact
  shape and order from ADR 0008; Impostazioni is appended, not inserted.
- Logic still lives in `TraccioCore`; the tab and its rows are presentation
  only.
- No new design tokens: the fourth tab composes `Card`, `NavigationLink`, and
  the existing icon-tile idiom from `AccountsView`'s account rows.

## Consequences

- A cross-tab invalidation signal became necessary in the same slice:
  `CategorizationView` can change a transaction's `effectiveCategoryID`
  (`POST /rules/apply`, `DELETE /categories/{id}`), and Movimenti/Panoramica
  are now sibling tabs to Impostazioni rather than screens reached through
  it. `DataFreshness` (`App/Sources/DataFreshness.swift`) is a shared token,
  injected once from `TraccioApp` via `.environment(_:)` and bumped by a
  successful `applyRules()`/`deleteCategory(id:)`; `DashboardView` and
  `TransactionsView` key their `.task(id:)` to it, so a bump triggers a full
  re-fetch — never a local recomputation, keeping `client/CLAUDE.md`'s "the
  backend owns every derived value" intact. This is a partial fix: creating
  an advance or recording a reimbursement has the same cross-tab staleness
  and is not wired to `DataFreshness` yet (`tasks/backlog.md`).
- Eventi, biometric lock, and backup/export now have a settled destination
  when they are built, instead of an open navigation question each would
  otherwise raise on its own.
- The design canvas (`docs/design/canvas/`) has no Impostazioni artboard and
  none is planned solely for this ADR — the screen is simple enough to
  compose from existing tokens, the same posture already taken for
  `TransfersView` and `CreateAdvanceSheet`.

## Alternatives considered

- **A toolbar entry point on Movimenti**, matching how Trasferimenti is
  reached today. Rejected: it was the first option tried, but Movimenti
  already owes account/category filter chips (`tasks/backlog.md`), and a
  second toolbar item starts the junk-drawer problem this ADR exists to
  avoid — Eventi and the rest would need a home just as much as Categorie e
  Regole does, and Movimenti is not it.
- **A gear icon on Panoramica.** Rejected: `DashboardView` has no toolbar at
  all today, and inventing a settings hierarchy hanging off one tab's corner
  for what is really a fourth peer surface is less honest than naming it as
  one.
- **Keep three tabs and decide per-screen later.** Rejected: this slice is
  precisely the second settings-shaped screen after "Categorie e Regole" was
  scoped (Eventi's total absence from the client was found in the same
  review), so "later" was already now.

## Revisit when

- A second settings-shaped screen (Eventi, biometric lock, backup/export)
  ships — confirms the tab earns its place rather than holding one entry
  indefinitely.
- The cross-tab staleness fix is extended to advances and reimbursements, at
  which point `DataFreshness` stops being categorization-specific in
  practice, only in its current callers.
