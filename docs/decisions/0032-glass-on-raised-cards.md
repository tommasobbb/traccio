# 0032 — Liquid Glass on `.raised` cards

Status: accepted
Date: 2026-09-15

## Context

ADR 0030 drew a hard line: "glass is chrome, never a content surface" —
`Card` and anything carrying a figure stay opaque no matter what. ADR 0031
then applied that chrome consistently across the whole app. On seeing the
result on device, the owner asked to push further: extend glass onto
selected content surfaces rather than keep it confined to navigation chrome.

The candidate surfaces are narrow by construction, not "everything": this
app's own elevation model (ADR 0008's 2026-09-08 tone revision) already
singles out **at most one `.raised` card per screen** as the protagonist —
Panoramica's hero, a detail screen's header. That is exactly the set ADR
0030 drew its line around, and exactly the set worth reconsidering: a
screen's *one* floating surface reading as glass is a deliberate, legible
accent, not the "translucent surface behind a number" ADR 0030 wanted to
rule out everywhere.

One inconsistency surfaced while building this: `EventDetailView`'s header
is already a `.raised` `Card`, but `TransactionDetailView`'s header was
bare text with no card at all — the two conceptually equivalent screens
had drifted apart. Fixed here as part of the same change.

## Decision

**`.raised` becomes Liquid Glass. `.flush` and `.resting` stay exactly as
ADR 0008 left them — opaque, `Palette.card`, their existing shadow
recipes.** This is a narrowing of ADR 0030's rule, not its reversal: glass
still never touches the *everyday* card — a Movimenti row, a day group, a
list of connections all stay opaque. Only the one card per screen already
designated "the protagonist" gets material instead of a shadow.

Concretely (`App/Sources/DesignSystem/Card.swift`):

- `Card(elevation: .raised)` renders as `.glassEffect(.regular, in:
  RoundedRectangle(cornerRadius: Radius.card, style: .continuous))` instead
  of `.background(Palette.card)` + the two-layer shadow + a
  `separatorSubtle` stroke border. The manual shadow is dropped for
  `.raised` — the system's own glass rendering already supplies a depth
  cue, and a flat-colour shadow stacked under a translucent surface read
  muddy in review.
- Every existing `.raised` call site inherits this automatically: the
  Panoramica hero (`DashboardView`), `EventDetailView`'s header,
  `PersonDetailView`'s summary, and the two loading skeletons that mirror
  them (`DashboardSkeleton`, `TransactionDetailLoader`).
- `TransactionDetailView`'s header moves from bare text to `Card(elevation:
  .raised)`, matching `EventDetailView` — the inconsistency above.
- Panoramica's period strip (prev/next + month/quarter/year picker) moves
  from an opaque flush-styled surface to `.glassEffect(.regular, in:
  RoundedRectangle(cornerRadius: Radius.row, style: .continuous))`. This one
  was already chrome by ADR 0030's *original* rule — a navigation control,
  not content — and simply got missed because that batch only touched
  Movimenti.

**What does not change:** `.flush`/`.resting` `Card`, every list row, every
sheet's `OptionListCard`, `Badge`, `IconTile` — none of these carry a
figure's own surface the way a `.raised` card does, and ADR 0030's "glass
is chrome, never a content surface" still governs all of them.

## Consequences

- Legibility risk, named directly: a large money figure (the hero's spend
  total, `TransactionDetailView`'s amount) now sits on a translucent
  surface instead of flat white/`Card`. This needs the same on-device
  judgment already owed for the rest of the coherence pass
  (`tasks/backlog.md` item 13) — light, dark, and Dynamic Type, specifically
  checking contrast of `Palette.ink`/`AmountText` over the glass in both
  appearances behind real (not placeholder) content.
- `docs/design/tokens.md`'s Glass table gains `.raised` `Card` and the
  Panoramica period strip; its "stays opaque" column drops `Card` at every
  elevation down to just `.flush`/`.resting`.
- No change to the accent, the ten `PaletteColor` tones, typography, radii,
  `.flush`/`.resting`'s own recipes, or anything outside `.raised`.

## Revisit when

- The on-device pass finds a legibility problem on `.raised` glass (a
  figure that reads worse than on the old opaque card) — the fix is a
  `.tint` on the glass or reverting that one call site to opaque, not
  reintroducing a manual shadow underneath it.
