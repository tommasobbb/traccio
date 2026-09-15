# 0034 — A brand triad and a rounded type voice

Status: accepted (first slice shipped; full reach still owed — see
"Consequences")

Date: 2026-09-16

## Context

The owner's assessment after the visual coherence and Liquid Glass batches:
the app is coherent now, but reads as "poor in visual identity" — the
system font at its default cut, one accent used sparingly by the 2026-09-08
"dose, non tinta" rule, no in-app brand mark beyond the app icon. That rule
was correct about its own diagnosis (surface area, not hue, was what made
early revisions read as loud or unfinished — `docs/decisions/0008-client-design-direction.md`'s
2026-09-08 revision) but its remedy — no filled colour block anywhere —
also removed every place the app could look like *itself* rather than a
well-executed default. Two changes, agreed directly with the owner:

1. A rounded type voice (SF Rounded via `design: .rounded`, still the
   system font — no new dependency, no Dynamic Type cost).
2. Three identity colours instead of one accent, used the way apps like
   isybank use theirs: **indaco notte `#14183C`**, **lime elettrico
   `#C8F000`**, **panna `#FFD9A0`** — with a rule about where they're
   allowed that keeps "dose, non tinta"'s actual lesson intact.

## Decision

### Typography

Every token in `App/Sources/DesignSystem/Typography.swift` moves from
`design: .default` to `design: .rounded`, figures included — a rounded
eyebrow next to a sharp hero figure would read as an inconsistency, not a
choice. `AmountText`'s `.monospacedDigit()` is orthogonal to `design` and
needed no change; tabular alignment is unaffected.

### The triad's rule

**Brand/structural surfaces may be a triad colour; a money figure or a data
row stays `ink` — colour there still has to mean something (category,
income, warning).** This is the same discipline ADR 0008's "Accent dosage"
established for a single colour, restated for three: the triad marks *what
screen you're in*, not *what number you're looking at*. Concretely:

- **`Palette.brandNight`** (`#14183C`, near-black navy in both
  appearances by design — a brand surface, not a system-adaptive neutral):
  a screen's one designated protagonist surface — today, `DashboardView`'s
  hero card and its loading-skeleton mirror. The same `.raised` card
  elevation already singles out one such surface per screen
  (`docs/decisions/0008-client-design-direction.md`'s 2026-09-08
  revision), so this is additive to an existing seam, not a new one.
- **`Palette.brandLime`** (`#C8F000`): the "you can touch this, or this is
  the number that matters" colour *on a `brandNight` surface* — the hero's
  own spend figure. Never used on a light surface: `#C8F000` on near-white
  has too little contrast to read as a control there, so `Palette.accent`
  (azure, untouched) keeps that job everywhere else.
- **`Palette.brandCream`** (`#FFD9A0`): the quiet neutral *inside* a
  `brandNight` surface — everywhere that surface would otherwise need
  `ink`/`inkSecondary`/`inkTertiary`, which don't have contrast against
  navy (`ink` swaps near-black/near-white with the *system* appearance,
  not with a card's own fixed background). Outside a brand surface,
  `brandCream` is not yet used for anything — "quiet fills, tiles, empty
  states" is scoped for a later slice (see Consequences).

`Income`'s green and `Warning`'s amber are untouched and take priority over
the triad wherever both could apply: a positive net or an income figure
inside the hero still reads in green, never lime or cream — see
`AmountText.colorOverride`'s doc comment for the exact mechanism (it only
ever substitutes for what would otherwise be an `ink`-family fallback,
never for a semantic colour).

### What shipped in this slice

- `Colors.xcassets`: `BrandNight`/`BrandLime`/`BrandCream`, each with a
  dark-appearance variant (`docs/design/tokens.md`'s hard rule that every
  colorset carries one) — `brandNight` lifted a few points in dark mode for
  an edge against `#0B0B0C`, `brandLime`/`brandCream` pulled back a little
  so a colour this saturated doesn't glow on an OLED-dark surface, the same
  adjustment the app icon's own dark variant already makes.
- `Card` gains an optional `background: Color?` (default `nil` → the
  existing `Palette.card`) — the one escape hatch for a brand surface,
  used nowhere else yet.
- `AmountText` gains an optional `colorOverride: Color?` for the same
  reason, scoped narrowly (see above) so it cannot be used to invent a new
  semantic colour, only to substitute one neutral for another.
- `DashboardView.heroCard` (and its `DashboardSkeleton` mirror) is the
  first, and so far only, brand surface: `brandNight` fill, `brandLime`
  spend figure, `brandCream` for the eyebrow/currency/"Entrate"/"Netto"
  labels, the divider, and the category ribbon's legend text (the ribbon's
  own segment colours are the ten `PaletteColor` tones, untouched).

## Consequences

- **Scope, deliberately narrow for this slice.** The triad's reach beyond
  `DashboardView.heroCard` — the tab bar, `EventDetailView`'s/
  `PersonDetailView`'s/`TransactionDetailView`'s own `.raised` headers, a
  wordmark in Panoramica's title, `brandCream` as a general tile fill — is
  **not** shipped here and is tracked in `tasks/backlog.md`. Each of those
  is either a bigger blast radius (the tab bar touches every screen) or a
  contrast question that genuinely needs a real device to answer (lime on
  a light surface is a known-bad pairing; lime/cream against the ten
  `PaletteColor` tones and `income`/`warning` is not yet checked stacked
  side by side on glass). Shipping the hero alone keeps every other screen
  exactly as before — if the hero doesn't read well on device, the
  rollback is one file.
- `docs/design/tokens.md` gains a "Brand triad" section recording the three
  values, their dark variants, and the rule above.
- No change to `Palette.accent`, the ten `PaletteColor` tones, `Income`/
  `Warning`, or the app icon in this slice — the icon's own cyan→azure
  gradient now sits alongside a navy/lime brand surface inside the app,
  which is a real (if secondary) inconsistency, tracked in
  `tasks/backlog.md` rather than guessed at here.

## Alternatives considered

- **Make `brandLime` the new `AccentColor`**, replacing azure everywhere
  the system accent is used (native toggles, `PillButton`, `FilterChip`,
  the tab bar's own tint). Rejected for this slice: azure has verified
  contrast on every light surface it appears on today; lime does not, and
  swapping the global accent would silently change every one of those
  surfaces at once with no way to verify contrast without a device pass
  first. `Palette.accent` stays azure; the question of whether it should
  eventually retire is left open, not decided by default.
- **Ship the triad across every `.raised` card and the tab bar in one
  commit**, matching the full ambition described in chat. Rejected: this
  is exactly the kind of change that needs on-device judgment before it
  reaches four more screens and the app's own navigation chrome —
  `tasks/backlog.md` item 13 already owes an on-device pass for less risky
  changes than this.

## Revisit when

- The on-device pass (`tasks/backlog.md` item 13) confirms the hero reads
  well in both appearances — then extend the triad to the other `.raised`
  headers (`EventDetailView`, `PersonDetailView`, `TransactionDetailView`)
  for the same "one protagonist surface" consistency ADR 0008 already
  established.
- A decision is made (with the owner, not assumed) on whether `brandLime`
  ever becomes the system `AccentColor`, and the app icon is revisited to
  match the triad rather than the retired-in-spirit azure gradient.
