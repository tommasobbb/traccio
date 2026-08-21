# 0005 — Categorization rules: deterministic string match, specificity ordering, full recompute

Status: accepted
Date: 2026-08-21

## Context

Categories foundations shipped (M2) the `Category` entity and both
`suggested_category_id`/`confirmed_category_id` columns on `Transaction`, but
deliberately no writer of `suggested_category_id` — `docs/domain.md` recorded
"There is no `set_suggested_category` yet; the categorization engine that would
call it is a later slice." That left the suggestion layer permanently `None`
and blocked two other M2 items (event totals by category, a meaningful
dashboard) that read `effective_category`.

`docs/domain.md` §Rule was, until this slice, three sentences: a rule maps a
transaction pattern to a category and writes `suggested_category_id`. It did
not say what a "pattern" matches against, how two matching rules resolve a
conflict, or when the engine runs. `tasks/ROADMAP.md` fixed the spirit —
"deliberately last and dumb... user-defined rules and manual assignment only.
No ML. The rules engine is cheap and its accuracy is knowable" — but not the
mechanics. This ADR settles the three questions that shape the implementation.

## Decision

**1. Matching is one of three deterministic, case-insensitive string
predicates over `description` — no regex.**

`RuleMatchKind`: `contains`, `starts_with`, `equals`. All compare against
`Transaction.description` (the raw bank text), never `display_description` —
no code path populates that field today, and matching against it would
silently change behaviour the day cleanup lands. No amount or account
conditions either. A rules engine whose accuracy the user cannot mentally
verify defeats the reason it exists instead of an ML model.

**2. Precedence is by pattern specificity, not a stored priority.**

When two rules match the same transaction, the rule with the longer `pattern`
wins (ties break by `created_at` ascending, then `id`). `"AMAZON PRIME"` beats
`"AMAZON"` because a longer literal match is, in practice, a more precise one.
The alternative — a stored `priority` column the user reorders — was rejected:
it adds a field to create/list/apply, a UI concept (drag to reorder), and a
second axis that can disagree with what the pattern itself suggests. Sharpening
a pattern is the only lever, and it is also the more legible one: reading a
rule's pattern tells you when it fires without cross-referencing a number.

**3. Applying rules is an explicit, full recompute — not incremental, not
sync-wired.**

`POST /rules/apply` re-evaluates every one of the user's rules against every
one of their transactions and writes the result in bulk via
`db/repositories.py::set_suggested_categories`. A transaction with no matching
rule gets an explicit `category_id: None`, clearing any stale suggestion from a
rule that has since been deleted or edited-by-delete-and-recreate. This is what
makes the operation idempotent: calling it twice in a row, or after deleting a
rule, always converges to the correct state rather than accumulating stale
suggestions. Wiring rule application into the sync pipeline (`docs/architecture.md`'s
"persist → run detection" step) is left for later, matching the precedent
already set by transfer detection, which also stayed an explicit
`GET /transfers/suggestions` call rather than sync-triggered.

A transaction already carrying a `confirmed_category_id` still gets a
suggestion computed underneath it — `services/categorization.py::suggest_categories`
is a pure function of `(rules, transactions)` with no knowledge of
confirmation. `domain/categories.py::effective_category` (confirmed wins, else
suggested) is what makes that harmless; if a user later clears a confirmation,
a live suggestion is already waiting rather than `None`.

## Consequences

- `db/repositories.py::set_suggested_categories` is now the second (and only
  other) writer of a category-id column, alongside `set_confirmed_category`.
  Both remain the *only* writers of their respective columns — `transaction_to_row`
  still writes neither, preserving the structural guarantee that a sync cannot
  touch either.
- Deleting a `Category` now also deletes every `Rule` targeting it
  (`delete_rules_for_category`), the same disposability already applied to a
  category's `suggested_category_id` references on transactions.
- `GET /rules` returns rules in evaluation order (not creation order), so what
  the user sees is the order rules actually fire in.
- A rule has no rename/edit endpoint: its two fields, `match_kind` and
  `pattern`, are what make it a distinct rule at all, so editing one is
  indistinguishable from deleting it and creating a new one.

## Alternatives considered

- **Regex patterns.** Rejected: opens a second pattern language to validate,
  document, and defend against catastrophic backtracking, for a product whose
  whole premise is a cheap, auditable engine.
- **A stored `priority` integer.** Rejected in favor of specificity ordering —
  see Decision 2.
- **Incremental application** (only re-evaluate new/changed transactions since
  the last run). Rejected for this slice: it requires tracking "since when",
  and the transaction volumes here (personal finance, not a fleet) make a full
  recompute cheap enough that the added bookkeeping is not yet worth it.

## Revisit when

- Matching against `display_description` becomes viable once cleanup exists —
  the fallback shape (raw first, cleaned as a fallback, or an explicit
  per-rule choice) is an open question at that point.
- Rule application is wired into the sync pipeline as a non-fatal detection
  step, once background sync scheduling (M3) makes "run it automatically"
  worth the added write path inside sync.
