# 0008 — Client design direction: a light, custom UI instead of stock native

Status: accepted
Date: 2026-08-22

## Context

`client/App/Sources/AccountsView.swift` states the M0 direction explicitly:
*"deliberately minimal and native — a `List` in a `NavigationStack` with
pull-to-refresh."* Every M1/M2 backend slice deferred its screen to "M3
client catch-up" on that assumption — plain system components, no visual
design work.

Starting the M3 catch-up, the product owner asked for something closer to
Revolut or Monzo: curated, modern, accattivante. Not a literal recreation
(`.claude/rules/data-safety.md` and the design skill's copyrighted-designs
rule both rule that out), but a custom visual language rather than stock
`List`/`Form` styling.

Before writing SwiftUI, a design canvas (four mockup screens — Dashboard,
Movimenti, Dettaglio anticipo, Conti — published as a design canvas
artifact) was built to let the direction be judged by eye rather than
described in prose. That canvas settled the direction this ADR records.

## Decision

**The client moves from stock native components to a custom, hand-styled
design system**, still built entirely in SwiftUI (no UIKit, no third-party
UI library — `.claude/rules/swift.md`'s "dependency-light" rule still
applies to *how* the custom look is built, just not to *which* components
render it).

Settled tokens (from the design canvas; full values and their Swift names are
in `docs/design/tokens.md` — that file is authoritative, this section is the
summary):

- **Palette**: cool neutral gray background (`#F5F5F7`), white cards, one
  brand accent (Apple's system indigo, `#5856D6`), a legible green for
  income (`#248A3D`) — spending stays in ink, not red, so the everyday list
  reads calm rather than alarming; a signed "net" figure carries the accent
  when positive.
- **Typography**: the system font (SF Pro) rather than a custom typeface,
  with tabular figures on every amount so columns of figures align.
- **Cards over rows**: 20px-radius white cards with a soft, low-opacity
  shadow, replacing `List`'s plain rows — used for every grouping (hero
  stats, connections, participants).
- **Custom iconography**: hand-drawn stroke SVG-equivalent (`SF Symbols`
  with consistent weight in SwiftUI, mirroring the canvas's stroke-icon
  style) instead of relying on default list chevrons/disclosure indicators.

The palette shipped with a first iteration (warm off-white background,
periwinkle-violet accent, Space Grotesk typeface) that read as generic
"AI product" rather than native-feeling; it was replaced with the values
above on review — see `docs/design/tokens.md`'s History section for both
sets of values.

**What does not change:**

- Logic still lives in `TraccioCore`; `App/` is still presentation only
  (`client/CLAUDE.md`) — a richer visual layer does not move derivation or
  networking into views.
- The backend still owns every derived value; no total, `effective_amount`,
  or spending share is computed client-side just because the UI got
  richer.
- The client still has no notion of tokens, and local storage is still a
  read cache, not a source of truth.

## Consequences

- **Dark mode, Dynamic Type, and accessibility no longer come for free.**
  Stock `List`/`Form` inherit these from the system; a custom palette and
  card system must implement a dark variant, must size text with the
  system's Dynamic Type categories rather than fixed points, and must carry
  explicit `accessibilityLabel`s where a decorative custom icon replaces a
  system one with a built-in label. This is real, ongoing work the M0
  direction avoided — budget for it in every M3 screen, not as a follow-up
  pass.
- **More SwiftUI code per screen.** A card-based layout with custom
  chrome is more view code than `List(items) { Row(...) }`. Reusable
  building blocks (a `Card` container, an `AmountText` view with the
  spend/income color convention baked in, a tag/badge view) belong in
  `App/Sources/DesignSystem/` early, so each new M3 screen composes them
  rather than re-deriving the look.
- **The design canvas's "Concept" elements are a backlog signal, not a
  UI task.** The Dashboard mockup includes a category donut and a trend
  line explicitly marked "Concept · richiede backend" — those chart
  components are cheap to build once the underlying aggregation exists, but
  building them against no data would be inventing a client-side
  derivation, which the second bullet above forbids. Backend work first
  (`tasks/backlog.md`), chart UI after.
- **`client/CLAUDE.md`'s claim that models are code-generated from
  `docs/api/openapi.json` was already false** before this ADR (the four
  existing models are hand-written) — corrected in the same change that
  records this decision, not caused by it.

## Alternatives considered

- **Keep the M0 native direction.** Rejected: it is not what was asked for,
  and a personal daily-use app the owner does not enjoy opening defeats
  M3's whole "done when" (`tasks/ROADMAP.md`: *"used every day for a month
  without wanting to open Revolut"*).
- **Adopt a third-party SwiftUI design-system package.** Rejected for now
  under the same "dependency-light" reasoning as every other top-level
  dependency in this repo (root `CLAUDE.md`): the custom system needed here
  is a handful of reusable views, not a framework's worth of components.
  Revisit only if the hand-built system grows unwieldy.

## Revisit when

- A second design canvas iteration changes the palette or type — update the
  tokens here rather than letting SwiftUI and the canvas drift apart.

## 2026-08-25 revision: dark mode

Item 6 of the M3 iPhone-trial roadmap (`tasks/backlog.md`). `Palette.swift`
moved from an `enum` of hardcoded `Color(hex:)` literals to named colors in a
new `App/Resources/Colors.xcassets`, each with an explicit light and dark
appearance — the `ColorScheme`-aware token layer this ADR's original
"Revisit when" anticipated. `Palette`'s public API is unchanged (still
`Palette.ink`, `Palette.card`, …), so no view in `App/Sources/` needed to
change; every consumer already went through `Palette` rather than a raw hex,
confirmed by grep before the change.

Two tokens stayed computed rather than becoming assets:
`separator`/`separatorSubtle` (a low-opacity overlay of `Palette.ink`, which
is itself dynamic, so the overlay reads correctly in both appearances without
a separate dark value) and `cardShadow` (stays pure black in both — a black
shadow is naturally near-invisible on a dark card over a dark background,
which is the correct dark-mode look; `Card`'s existing `separatorSubtle`
border is what defines the edge once the shadow stops reading). Full values
are in `docs/design/tokens.md`, updated in the same change.

Dark values are not a mechanical inversion of the light ones: where Apple has
its own dark system color for the same hue (accent, income, warning, category
red), that value was used instead of deriving one; category-chart and ink
scale values were hand-raised in luminosity rather than opacity-flipped,
which reads muddy on a near-black background.

**Verified**: `xcodebuild` macOS build clean, `swift test` (225 cases) and
`make test-app` (121 cases) green — dark mode has no logic to unit test, so
build success plus a manual light/dark visual pass per screen is the
verification of record, same as the original ADR 0008 slice.
