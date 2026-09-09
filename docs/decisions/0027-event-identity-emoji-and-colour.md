# 0027 — Event identity: a free-text emoji, a token colour, one update endpoint

Status: accepted
Date: 2026-09-09

## Context

The Eventi screen was the last one built entirely from bare tokens with no
visual identity per row — `EventRow` was a name, a member count, and a net
total, no leading tile (unlike `TransactionRow` and `AccountsView`, which both
lead with an `IconTile`). The owner asked for it to be "più carina, con
immagini o emoticon", and for the screen to answer the question it exists for.

Two facts shaped the decision:

1. **Accounts and categories already have `color` + `icon`** (ADR 0017), a
   closed `PaletteColor` vocabulary plus a semantic icon enum the client maps
   to an SF Symbol. That is the established pattern for "tell rows apart at a
   glance".
2. **An event is user-created from nothing** — there is no bank, no provider,
   no product name to source an image from (unlike a connection's
   `institution_logo`, ADR's dark-mode note). Whatever identity it gets, the
   user types.

## Decision

**An event carries an optional free-text `emoji` and an optional `color`
token, and a single `POST /events/{id}` replaces every editable field.**

### 1. `emoji` is free text, not a closed enum — a deliberate exception to ADR 0017

ADR 0017 forbids free strings for `color`/`icon` for two concrete reasons:
a user-chosen hex has no dark-mode variant in `Colors.xcassets`, and an SF
Symbol name is an unvalidated, OS-version-dependent string. **Neither applies
to an emoji**: it renders itself in both appearances with no asset, and it
needs no client-side name mapping. So an event's *icon* slot is a
`str | None` holding one emoji, while its *colour* slot stays the shared
`PaletteColor` enum — colour is still a closed vocabulary because that reason
(no dark pair for an arbitrary hex) is unchanged.

The one thing that must be enforced is that the value *is* one emoji and not a
caption. `domain/emoji.py::validate_emoji` is the pure check, called at the
API edge (a `BeforeValidator` on the request schema, so a bad value is a
`422`): it trims, rejects an ASCII letter/digit or whitespace anywhere in the
string, caps the length at 8 code points, and — lacking stdlib grapheme
segmentation — counts emoji "clusters" (a base pictograph not glued to a
previous one by a ZWJ; a run of regional indicators is one flag) and requires
exactly one. This tells "🎂" from "🎉🎂" and from "birthday"; it is not a
full Unicode oracle and does not need to be.

### 2. `color` is `PaletteColor | None`, reusing everything

`_token_column(PaletteColor)` on `EventRow` (a fixed `VARCHAR(32)`, so a new
palette member never needs a widening migration — ADR 0017's `_token_column`
rationale), `PaletteColor | None` on the domain model and `EventResponse`,
`Palette.color(_:)` on the client. `None` falls back to `.slate`, the same
neutral default `IconTile` uses everywhere.

### 3. One update endpoint, not two action endpoints

ADR 0017 gave accounts two writes — `POST /accounts/{id}/rename` and
`POST /accounts/{id}/appearance` — because an account is renamed and recoloured
from two different places in the app. **An event has exactly one editor**
(`EventEditorSheet`, which also creates), so it gets one write:
`POST /events/{id}` with `UpdateEventRequest {name, emoji, color, start_date,
end_date}`, a full replace of the fields that editor owns. `status` is not in
the body — close/reopen keep their own endpoints. `CreateEventRequest` gains
the same `emoji`/`color` fields. Both are optional-with-default on the wire:
an omitted key means "not set / cleared", so the client sends whatever its
fields hold and clearing a value just drops it from the payload — no
hand-written `encode(to:)` for explicit `null` (unlike ADR 0024's
mandatory-but-nullable `/settings`).

### 4. `EventTile` — two anatomies

`App/Sources/DesignSystem/EventTile.swift`:

- **with emoji** — the emoji centred on a *pale wash* of the event's colour
  (`Palette.color(...)` at `0.16`, hairline border at `0.32`). The opacity
  rides on an already theme-dynamic colour, so it resolves in both
  appearances (the `Palette.separator` technique). ADR 0008's tone revision
  rejected a pale fill *under a thin coloured glyph* as muddy — but an emoji
  is its own colour, and an emoji on a *saturated* fill is unreadable, so the
  wash is correct here specifically.
- **without emoji** — the standard `IconTile`: solid `PaletteColor` fill,
  white `calendar` glyph.

The editor offers a default-emoji grid, so most events land in the first case.

## Consequences

- New: `domain/emoji.py` (+ `test_emoji.py`), `events.emoji` /
  `events.color` columns (migration `5f407e810deb`, nullable, no backfill),
  `emoji`/`color` on `Event` / `EventRow` / both mappers / `EventResponse` /
  `CreateEventRequest`, `UpdateEventRequest` schema, `update_event` repository
  fn, `POST /events/{id}` route.
- Client: `emoji`/`color` on `EventResponse` / `CreateEventRequest`, new
  `UpdateEventRequest` model, `APIClient.updateEvent(id:_:)`, `EventTile`,
  `EventEditorSheet` (replaces `CreateEventSheet`), `EventsViewModel.createEvent`
  and `EventDetailViewModel.updateEvent` gain the fields, `EventTile` lands in
  `EventRow`, `EventDetailView`'s header, `EventPickerSheet`, and
  `TransactionDetailView`'s event chip.
- `docs/domain.md` §Event and `docs/design/tokens.md` (the `EventTile`
  anatomy) updated.
- The emoji validator is an approximation. A value that is technically two
  grapheme clusters the check happens to accept, or a brand-new emoji the
  code-point ranges miss, is a possible false result — acceptable for a
  single-user app; the fallback is always the `calendar` tile.

## Alternatives considered

- **A closed `EventIcon` enum**, exactly like `AccountIcon` — rejected by the
  owner: no flags, no "🎂", far less expressive for the "trip / renovation /
  wedding" cases `docs/domain.md` frames.
- **Emoji *or* icon**, a two-field either/or — rejected: doubles the model,
  the picker, and the tests for little gain over "any emoji works".
- **A remote image / uploaded photo** — rejected: no provider to source one
  from, and image upload/storage is a whole subsystem this does not need.
- **Two action endpoints** (`/rename` + `/appearance`) mirroring ADR 0017 —
  rejected: an event has one editor, so one write.

## Revisit when

- A second place needs to edit just an event's colour (then `/appearance`
  might earn its keep).
- The emoji check rejects something a user legitimately wants — widen the
  code-point ranges rather than loosening the one-cluster rule.
