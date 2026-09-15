# 0032 — Liquid Glass on `.raised` cards

Status: **rejected** (tried on device 2026-09-15/16, reverted 2026-09-16)

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

## Decision (as shipped, then reverted)

**`.raised` became Liquid Glass.** `.flush` and `.resting` stayed exactly as
ADR 0008 left them — opaque, `Palette.card`, their existing shadow recipes.
This was framed as a narrowing of ADR 0030's rule, not its reversal: glass
still never touched the *everyday* card — a Movimenti row, a day group, a
list of connections all stayed opaque. Only the one card per screen already
designated "the protagonist" got material instead of a shadow.

Concretely (`App/Sources/DesignSystem/Card.swift`): `Card(elevation:
.raised)` rendered as `.glassEffect(.regular, in: RoundedRectangle(...))`
instead of `.background(Palette.card)` + the two-layer shadow + a
`separatorSubtle` stroke border, with the manual shadow dropped entirely.
Panoramica's period strip moved to the same glass treatment.

**`TransactionDetailView`'s header moving to `Card(elevation: .raised)`,
matching `EventDetailView`, is kept** — that part was a real consistency
fix, independent of whether `.raised` renders as glass or opaque, and it
now inherits the opaque `.raised` recipe below like every other screen.

## Why this is rejected

Judged on a real device the day after shipping: a large money figure
(the hero's spend total, `TransactionDetailView`'s amount) sitting on a
translucent surface reads worse than on the old opaque card — exactly the
legibility risk this ADR named as "the first thing to judge on device"
(`tasks/backlog.md` item 13). The owner's call after seeing it live: revert.

This also removes the drift ADR 0031 (chrome pass) and ADR 0032 were
threading carefully around — glass creeping from pure navigation chrome
onto a content surface that carries a figure. ADR 0030's original line
("glass is chrome, never a content surface") holds again, without
exception.

## Consequences of the revert

- `App/Sources/DesignSystem/Card.swift`: `.raised` is opaque again —
  `.background(Palette.card)` + `clipShape` + `separatorSubtle` border +
  the two-layer near/far shadow (`.04` opacity radius 1 y 1, `.22` opacity
  radius 14 y 8). The `if elevation == .raised` branch in `Card.body` is
  gone; `Card` is back to one body for all three elevations.
- `App/Sources/Dashboard/DashboardView.swift`'s period strip is back to an
  opaque flush-styled surface (`Palette.card` + border), not glass.
- `docs/design/tokens.md`'s Glass table drops `.raised` `Card` and the
  Panoramica period strip; the elevation section documents `.raised` as
  opaque again.
- `TransactionDetailView`'s header stays a `Card(elevation: .raised)` — the
  one piece of this batch that was a genuine fix, not a glass experiment.
- No change to the accent, the ten `PaletteColor` tones, typography, radii,
  or `.flush`/`.resting`'s own recipes — none of those were touched by
  this ADR in the first place.

## Revisit when

Don't, without a concrete new legibility mitigation (a `.tint` strong
enough to read reliably, or a different glass variant) validated on device
*before* it ships — the whole point of this record is to stop the same
experiment from being retried blind in a few months.
