# 0035 — Glass narrowed to chrome only; the brand triad withdrawn

Status: accepted
Date: 2026-09-17

## Context

Two on-device judgments after real daily use of the `feat/visual-coherence`
branch (ADRs 0030–0034, not yet merged to `main`):

**1. Liquid Glass reads wrong on in-screen controls.** ADR 0030's rule was
"glass is chrome, never a content surface," and it correctly kept `Card` and
every money figure opaque. But "chrome" was applied to *component identity*
(a `PillButton` is chrome because ADR 0030 said so) rather than to *where the
component sits on screen*. The result: `FilterChip`, `IconButton`, and
`PillButton` all render in glass wherever they appear, including deep inside
Movimenti's or Conti's scrollable body — not just at a screen edge. No app
built by Apple does this: their own glass is the tab bar and the toolbar,
never a chip or a button living in the content itself. ADR 0031 then applied
this same over-broad rule uniformly across the app, multiplying the
inconsistency instead of catching it.

**2. The brand triad (ADR 0034) is withdrawn, not extended.** Navy
`Palette.brandNight` / lime `Palette.brandLime` / cream `Palette.brandCream`
on Panoramica's hero card was the app's first colour identity beyond the
accent, shipped as a deliberately narrow first slice pending an on-device
pass (`tasks/backlog.md` item 13, and item 13a's plan to extend it further).
On device, the owner's call is to **step back from that specific palette
entirely** — not tune its dark-mode values or extend its reach (0034's own
"Revisit when"), but reopen the color question from scratch, unhurried.
Nothing replaces it yet; that is deliberate.

## Decision

**1. The correct criterion for glass is position, not component identity: is
this element anchored to a screen edge (the tab bar, a toolbar, a sheet's own
bottom action bar), or does it live inside the scrollable body?** Anchored →
glass. In-body → opaque, back to the flat fill every one of these components
had before ADR 0030 (`PillButton`, `FilterChip`, `IconButton`,
`SelectionSheet`'s closed control, `TrackingStartView`'s primary/secondary
pair, `TransferSuggestionCard`'s "Ignora", the Filtri sheet's "Applica"
button, Movimenti's active-filter-token row). The two full-width bottom
action bars (the Filtri sheet's, Movimenti's transfer-selection bar) keep
their glass — they are chrome anchored to the sheet/screen's own bottom edge,
the same idiom as the tab bar; only the button *inside* each bar goes back to
a solid fill. `ActionButtonStyle` (`App/Sources/DesignSystem/ActionButtonStyle.swift`)
shares the flat accent fill across the three identical primary-CTA call
sites instead of hand-rolling it three times; `TrackingStartView`'s secondary
button and `TransferSuggestionCard`'s "Ignora" keep their own distinct
pre-0030 looks (card+accent-border vs. neutralFill+ink) rather than being
forced into a shape neither ever had.

Unchanged, because they already satisfy the position criterion: the tab bar
(`.tabBarMinimizeBehavior`), every native toolbar, `.scrollEdgeEffectStyle`
(the chrome's own edge effect), and `.pickerStyle(.menu)`'s system-provided
glass.

**2. The triad's three colorsets, `Palette` entries, and the two API hooks
that existed only to carry it (`Card.background`, `AmountText.colorOverride`)
are removed.** Panoramica's hero returns to the plain white `Card` at
`.raised` the 2026-09-08 "dose, non tinta" revision established — scale
(`Typography.heroFigure`) and elevation still carry its protagonist billing,
which is exactly what that revision's diagnosis already said should do the
work, colour or not. `Palette.accent` (azure `#087ED7`) is untouched: it was
never part of the triad and was not in question.

**The rounded type voice (`design: .rounded`, `Typography.swift`) is kept.**
It was bundled into the same commit as the triad but is a separate,
unrelated axis — no file overlap, no owner objection to it specifically —
and stays.

## Consequences

- `docs/design/tokens.md`'s "Glass" table is rewritten around the
  edge-vs-body criterion; its "Panoramica hero" and "Brand triad" sections
  are rewritten/removed to match.
- ADRs 0030–0032 keep their own analysis (glass-as-chrome was the right
  instinct; the ADR 0032 on-`.raised`-card experiment was independently
  rejected already) — annotated here rather than rewritten, same as 0009 was
  annotated by 0033.
- ADR 0034 is annotated as superseded on its color half; its typography half
  stands.
- `tasks/backlog.md` item 13a (extending the triad) is dropped; a new open
  item records that the color question — accent, data tones, and whether the
  app gets any color identity beyond the accent — is being reopened with no
  default assumed, to be worked through with the owner directly rather than
  guessed at in another commit.

## Alternatives considered

- **Keep glass everywhere but reduce its opacity/tint intensity.** Rejected:
  the complaint is about *where* material appears relative to the tab
  bar/toolbar convention, not its strength — tuning the same wrong placement
  would still look wrong.
- **Keep the triad but only on Panoramica, never extend it (freeze ADR 0034
  as-is instead of withdrawing it).** Rejected per the owner: the ask was to
  remove the colors now and rethink, not to leave a provisional choice
  standing indefinitely under the banner of "not extended yet."

## Revisit when

- A new color direction is worked out and ready to ship — starts a fresh ADR
  rather than reviving 0034 verbatim, since the triad's specific hues
  (`#14183C`/`#C8F000`/`#FFD9A0`) are withdrawn, not just paused.
- The on-device pass (`tasks/backlog.md` item 13) is finally done — it now
  also covers the flat-fill controls this ADR restores.
