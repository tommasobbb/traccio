# 0030 — Liquid Glass in the chrome, deployment target raised to 26

Status: accepted
Date: 2026-09-15

## Context

The client's look has been correct but flat since the 2026-09-08 "dose, non
tinta" revision (`0008-client-design-direction.md`): five accent hues were
rejected in three days, and the diagnosis was that the variable that kept
failing was never the hue — it was how much surface it covered. The rule
since then is that the accent marks only what you touch, never a filled
surface. That rule is sound and stays, but its side effect is a UI with very
little material depth: two `.regularMaterial` call sites in the whole app,
zero use of any translucent or reflective surface anywhere in the chrome.

The owner asked for the client to feel more "liquid glass" and visually
sharper, including specifically better-built dropdown/picker menus with
icons next to their options. This repo's Xcode is 26.4.1 (SDK iOS 26.4 /
macOS 26.4); the owner's iPhone runs iOS 27.0 and this Mac runs macOS 26.2.
The client's deployment target was still iOS 17.0 / macOS 14.0 with zero
`#available` branches anywhere in `App/Sources`.

## Decision

**1. Raise `client/Project.yml`'s deployment target to iOS 26 / macOS 26.**
Both target devices already exceed it, so this costs nothing and lets the
client call the native Liquid Glass APIs directly — no `#available` gating,
no second visual code path to maintain. `TraccioCore`'s `Package.swift`
platforms stay at `.iOS(.v17)` / `.macOS(.v14)`: it is pure logic with no
SwiftUI, and keeping its floor low keeps `swift test` (`make test-core`)
maximally portable. Cost, accepted explicitly: the app no longer runs below
iOS 26 — irrelevant for a personal tool with one iPhone and one Mac as its
entire fleet (`0002-personal-tool-first.md`).

**2. Liquid Glass lives in the chrome. Card stays untouched.** This is the
same discipline as "dose, non tinta," restated for material instead of hue:
glass is depth without pigment, so it is exactly the vocabulary the
2026-09-08 revision was reaching for. Concretely:

- Glass: the tab bar (`.tabBarMinimizeBehavior(.onScrollDown)`, iOS-only —
  the modifier is `@available(macOS, unavailable)`), toolbars, sheets'
  bottom action bars, `PillButton`, `IconButton`, `FilterChip`, the new
  `SelectionSheet`'s closed control.
- Not glass, ever: `Card` (`App/Sources/DesignSystem/Card.swift`) and
  anything that carries a figure — the three-level shadow elevation model
  from the same 2026-09-08 revision is untouched. If a screen looks flat,
  the fix stays hierarchy (elevation, type scale, whitespace), never a
  translucent surface behind a number.

**3. The screen background gets a barely-there neutral gradient**
(`Palette.backgroundElevated`, `docs/design/tokens.md`), specifically so the
glass in the chrome has something to refract. This is not a reprise of the
rejected accent bands: it carries no hue, only a luminosity step within the
existing neutral `Background` token.

**4. Dropdown/picker menus get rebuilt, not just re-skinned.** The private
`optionCard`/`optionRow` pattern already in `TransactionFiltersSheet` (swatch
+ checkmark + hairline dividers) becomes a shared `OptionListCard`/`OptionRow`
component with an `IconTile` for data-backed options (accounts, categories)
instead of a bare 10pt swatch. The four bare `.pickerStyle(.menu)` instances
(account/category-adjacent pickers) move to this shared component or to a
native `Menu` with `Label(_, systemImage:)` per row for small closed
enumerations (`AccountKind`, 6 cases) — both render in Liquid Glass on iOS 26
automatically, so the "prettier menu" ask and the "adopt Liquid Glass" ask are
the same piece of work.

## Consequences

- `docs/design/tokens.md` gains a **Glass** section naming exactly which
  components carry `.glassEffect`/`.buttonStyle(.glass)` and which don't, the
  same way it already names the three card elevations.
- `0008-client-design-direction.md` gets a dated revision pointing here,
  since this changes the chrome material story that ADR owns.
- No change to the accent, the ten `PaletteColor` tones, typography, radii,
  or the elevation model — this ADR is additive to the chrome layer only.
- The on-device visual pass owed since the 2026-09-08 tone revision
  (`tasks/backlog.md`, item 13) folds into this work's own on-device pass
  rather than staying a separate backlog item.
