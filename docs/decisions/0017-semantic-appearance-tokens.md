# 0017 — Semantic appearance tokens for accounts and categories

Status: accepted
Date: 2026-08-25

## Context

Real daily use surfaced a first, concrete gap in the "Daily driver, davvero"
milestone: accounts are indistinguishable in the client. `Account.name` is
the bank's own product name (`details["product"]`, `providers/*.py`), which
several accounts at the same bank often share, and it is silently overwritten
on every sync (`db/repositories.py::upsert_account`) — there was never a
place a user-chosen name could survive. The same milestone plans a colour and
icon for categories next (a later slice), and the two problems are the same
shape: a user wants to tell rows apart at a glance, and today has no way to.

## Decision

**Two new, backend-owned appearance fields — `color` and `icon` — join a
`display_name`-producing `alias`, for both `Account` (this slice) and
`Category` (the next one).** Colour is a single enum, `ColorToken`, **shared**
between the two entities: `blue, indigo, purple, pink, red, orange, amber,
green, teal, slate`. Icons are **two separate enums**, `AccountIcon` now and
`CategoryIcon` in the categories slice — the vocabularies are disjoint (an
account picker has no use for a dozen food icons), while colour genuinely is
one shared palette across the app.

**Fixed vocabularies, not free hex strings or SF Symbol names.** The client's
`Colors.xcassets` is the only place a colour has an explicit dark-mode
variant (ADR 0008's dark-mode revision); a user-chosen `#2A78D6` would have no
dark counterpart and would silently break that contract the first time the
system switches appearance. An SF Symbol name is worse: an unvalidated,
OS-version-dependent string that renders nothing when wrong, and it would
couple the backend to Apple's icon catalogue for no reason — the backend has
no business knowing SF Symbols exist. A closed enum keeps every value
representable in both appearances and lets the client own the icon mapping
entirely as a presentation-layer fact (`IconTile.swift`).

**Members are named semantically, not decoratively** (`AccountIcon.savings`,
not `banknote`): the same reasoning as above, one level down.

**A new `_token_column` helper, not `_enum_column`.** `_enum_column`
(`db/models.py`) sizes its `VARCHAR` to the longest *current* member, which is
exactly what has already cost this codebase two width-widening migrations
(`d1f4b6a29c73`, `e2c4a8f1b6d3`) when a later member turned out longer.
`_token_column` uses a fixed `VARCHAR(32)` instead — comfortably wide for
every planned token, so adding one never needs a migration. This is a
deliberate middle ground: `Text` (the "opaque, unbounded value" choice used
for `identification_hash`) would throw away the fact that this is in fact a
short, closed vocabulary.

**The preference lives on the backend, never in client-local storage.**
`docs/architecture.md`'s "local storage is a read cache, not a source of
truth" rule applies here exactly as it does to every other user-owned value —
an alias or a colour set only in `UserDefaults` would vanish on reinstall and
never sync across a second device later.

**`display_name` is resolved once, server-side.** `alias` if the user set
one, else `name`, else `null` — the single place this fallback exists
(`domain/accounts.py::display_name`), replacing three different, inconsistent
placeholder strings the client had grown independently (`AccountsView`:
"Conto senza nome"; `TransactionsView`/`TransactionDetailView`: "Conto").

**Two action-style endpoints, not one.** `POST /accounts/{id}/rename` (body:
`{alias: str | null}`, mandatory-but-nullable so "clear it" is never
ambiguous with "field omitted") and `POST /accounts/{id}/appearance` (body:
`{color, icon}`, both mandatory-but-nullable, always a full replace). Rename
is text and mirrors `POST /categories/{id}/rename` exactly; appearance is
tokens and always both-or-nothing — there is no partial "just the colour"
case worth a third endpoint for.

## Consequences

- `upsert_account` gained an explicit invariant, called out at the write
  site: it must never touch `alias`/`color`/`icon` on an existing row. This
  is now covered by a dedicated regression test
  (`test_upsert_account_preserves_user_owned_fields`) — the load-bearing
  guarantee of the whole feature.
- Client gained `App/Sources/DesignSystem/Spacing.swift` and `Radius.swift` —
  the values already existed as bare literals at ~40 call sites
  (`docs/design/tokens.md`'s own numbers); this milestone's new views are the
  first to use named tokens instead. Converting the rest of the app is a
  separate, tracked cleanup (`tasks/backlog.md`), not folded in here.
- `Colors.xcassets` gained 20 new colorsets (10 tones × solid + tint), each
  with an explicit dark-appearance variant computed by blending the light/
  dark base toward white/black respectively — a reasonable systematic
  default, not the fully hand-tuned pass ADR 0008 asks for; refining any one
  of them by eye is a fair follow-up once the feature is used for real.
- A mandatory-but-nullable Swift request field needs a hand-written
  `encode(to:)`: Swift's synthesized `Encodable` conformance uses
  `encodeIfPresent` for an `Optional` stored property, which *omits* the key
  entirely when the value is `nil` — exactly the wrong shape when the backend
  requires the key present. `RenameAccountRequest` and
  `SetAccountAppearanceRequest` both need this; a client-side regression test
  pins the explicit-`null` behavior for each so this cannot regress silently.
- `docs/api/openapi.json` schema descriptions come straight from Pydantic
  model and route docstrings — a `test_schema_never_leaks_token_fields`
  data-safety guard (`.claude/rules/data-safety.md`: bank tokens must never
  appear in the exported schema) turned out to fire on the plain English word
  "token" in a docstring, unrelated to any secret. The domain enum is named
  `PaletteColor`, not `ColorToken`, and every account-facing docstring avoids
  the word, to keep that guard meaningful rather than working around it.

## Alternatives considered

- **Free hex strings.** Rejected: no dark-mode counterpart, the core reason
  above.
- **`(user_id, parent_id, name)`-style per-entity colour enums** (a
  `CategoryColor` distinct from `AccountColor`). Rejected: there is one
  colour vocabulary in this app, not two: a shared `ColorToken` means one
  asset set and one picker grid, reused wherever a colour is chosen.
- **A single combined `AppearanceIcon` enum for both accounts and
  categories.** Rejected: the two vocabularies are disjoint by nature (bank/
  card/wallet vs. groceries/dining/transport/…) and a shared enum would
  either bloat every picker with irrelevant members or need per-context
  filtering that a plain two-enum split avoids entirely.

## Revisit when

- Categories land their own `color`/`icon` (the next slice) — this ADR
  already covers both, so that slice needs no ADR of its own, only the
  structural two-level-hierarchy decision.
- The generated Spacing/Radius tokens' repo-wide adoption becomes its own
  task (`tasks/backlog.md`).
