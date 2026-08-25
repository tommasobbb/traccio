# 0018 — A strict two-level category hierarchy

Status: accepted
Date: 2026-08-25

## Context

The second gap the "Daily driver, davvero" milestone set out to close (task
2/6, after account alias/colour/icon in ADR 0017): categories are flat names
with no way to group related spending. `Category`'s own docstring recorded
this as a deliberate 2026-08-21 decision — "no parent for hierarchy (YAGNI)" —
made when the foundations slice had nothing yet to justify the complexity.
Real use since (M3, three banks, ~537 transactions) surfaced the actual need:
"Groceries" and "Dining out" cover food spending well enough, but "Housing"
hides rent, utilities, and maintenance behind one number, and a rule
("AMAZON PRIME" → a category) can currently only be as specific as a whole
root, never "Subscriptions › Streaming".

## Decision

**A category nests at most two levels deep: a root, or a child of a root —
never a grandchild.** `Category` gains `parent_id: UUID | None`;
`domain/categories.py::validate_parent` is the single place the depth rule is
checked (`REASON_DEPTH_EXCEEDED` when a proposed parent is itself a child,
`REASON_SELF_PARENT` when a category would become its own parent), because the
schema cannot portably express "at most two levels" — a self-referential
foreign key alone permits arbitrary depth.

**Colour and icon land in the same slice** (see ADR 0017, which already
covers the shared `ColorToken`/vocabulary decision) — every category now
carries a `color` (never `None`) and an optional `icon`, the same appearance
model as accounts.

**Uniqueness stays `(user_id, name)`, global — not per parent.** The
tempting alternative, `(user_id, parent_id, name)`, is unreliable on
PostgreSQL: `NULL` compares distinct to itself, so two same-named *roots*
(`parent_id IS NULL` both times) would both satisfy that constraint — the
exact case a name-uniqueness rule exists to prevent. Fixing that needs a
partial index or a sentinel value, both schema cleverness with no product
benefit: every client surface (a picker, a filter chip, a rule's category)
renders a category by **bare name**, so two identically-named children under
different roots would be indistinguishable in the UI regardless of what the
database allowed. The accepted cost: you cannot have `Casa › Bollette` and
`Auto › Bollette`; you write `Bollette casa` / `Bollette auto`. Relaxing a
global constraint to a scoped one later is a trivial migration; tightening one
is not, so global is the safer default to ship first.

**Deleting a category with children is refused (`409
category_has_children`), checked before the existing confirmation-in-use
refusal.** Both are the same shape of guard — "this delete would silently
discard something the user organized on purpose" — and the structural one is
checked first because, unlike a confirmation, there is no client-side
workaround for it (you cannot "unconfirm" a child into non-existence; you
have to actually delete or move it). Cascading delete was rejected outright:
deleting a root's children as a side effect could delete rows the user
confirmed a category on, which is exactly the automated write to
`confirmed_category_id` `docs/domain.md` forbids.

**Reparenting is its own action**, `POST /categories/{id}/move`
(`{parent_id: UUID | null}`), not folded into rename or delete-and-recreate.
Delete-and-recreate is unavailable anyway for a category the user has
confirmed anywhere (`409 category_in_use`) — precisely the categories worth
reorganizing. Moving a category that itself has children under a new parent
is refused (`409 category_has_children`, the same reason code as delete):
promoting it into a child position would strand its own children a third
level deep, which the rule above forbids.

**A rule may target a child.** `services/categorization.py` needed zero
changes — `Rule.category_id` is just a foreign key, and precision is the
entire point of a child category (`"AMAZON PRIME"` matching `Subscriptions ›
Streaming` rather than the whole of `Subscriptions`).

**`GET /transactions?category_id=` rolls up.** Naming a root now returns that
root's transactions plus every child's — the router expands `{category_id} ∪
children` before querying, and `list_transactions`'s `category_id` parameter
became `category_ids: Sequence[UUID] | None`. Without this, tapping a root row
in the (future) Panoramica category breakdown would drill through to an
under-count that contradicts the chart above it — there is no product need
for a root-only, non-rolled-up filter.

**`GET /categories` stays flat, with `parent_id` — not nested.** It feeds a
picker, the rules editor, and filter chips, all of which want a flat list to
render with indentation; a dashboard's category breakdown (a later slice,
task 4) is nested because there the rollup *is* the payload. Different shapes
for different purposes, each justified by its consumer. The list is ordered
root-then-its-own-children (`db/repositories.py::list_categories` — a single
`ORDER BY name` fetch, regrouped in Python, not a SQL self-join), mirroring
`GET /rules` already returning evaluation order rather than creation order.

## Consequences

- `docs/api/openapi.json` gains three new fields on `CategoryResponse`
  (`parent_id`, `color`, `icon`) and three new schemas
  (`SetCategoryAppearanceRequest`, `MoveCategoryRequest`, `CategoryIcon`).
  `CreateCategoryRequest` gains optional `parent_id`/`color`/`icon`.
- Migration `b2c3d4e5f6a7`: three columns, a self-referential FK (behind the
  usual SQLite guard), and a **literal**, frozen-in-time name→(colour, icon)
  backfill for the 13 default root categories already seeded in production —
  deliberately not imported from `domain/categories.py`, so a later edit to
  the default tree cannot silently rewrite this migration's history. Any
  other existing row (a category the user typed by hand) gets the neutral
  `slate` default.
- The migration does **not** create the default tree's new child categories
  for the already-seeded production account — `POST /categories/defaults`
  only ever seeds when a user has zero categories, and inserting rows in a
  migration would be exactly the surprise mutation that guard exists to
  prevent. The user's own default children come from the client UI, two taps
  each; a one-off `scripts/` seeder is a fair follow-up if that turns out to
  be annoying (`tasks/backlog.md`).
- The client's `CategoryEditorSheet` now edits name, colour, and icon
  together (mirroring `AccountEditorSheet`), and gains a `Mode.create(parentID:)`
  case so a root row's "+" creates a child directly, with no in-sheet parent
  picker needed. A dedicated "move to a different root" UI affordance is not
  built in this slice — the endpoint and client method exist and are tested,
  the UI is a small follow-up.
- `TraccioCore.categoryTree(_:)` is the one pure function that regroups the
  flat `GET /categories` list into roots-with-children for rendering; it
  groups purely by `parentID` rather than assuming the backend's own
  interleaved order, so it stays correct even if a caller re-filters or
  re-sorts before calling it.

## Alternatives considered

- **`(user_id, parent_id, name)` uniqueness.** Rejected — the PostgreSQL
  `NULL`-distinctness problem above, and no client surface would benefit from
  it (every picker shows bare names).
- **Cascading delete of a root's children.** Rejected — would risk an
  automated write to `confirmed_category_id`.
- **Arbitrary-depth hierarchy.** Rejected as scope creep: nothing in the
  product need (rent/utilities/maintenance under housing; a rule specific
  enough to name a streaming subscription) asks for a third level, and every
  additional level multiplies the UI and validation surface for no requested
  benefit.

## Revisit when

- Merging one category into another becomes worth building (`tasks/backlog.md`)
  — the natural unblock for the `409 category_in_use` dead end, independent
  of this hierarchy.
- A "move to a different root" UI affordance is asked for; the backend
  already supports it.
