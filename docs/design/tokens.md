# Design tokens

The settled values behind the client's light UI (`docs/decisions/0008-client-design-direction.md`).
This file is the one to read before writing SwiftUI — it gives you the exact
values and their Swift names. `docs/design/canvas/` holds the mockup sources if
you need to *look* at a screen instead; the published canvas artifact (linked
from ADR 0008) is the same thing rendered.

Direction: light and airy, Apple-native — system font, a distinctive but
restrained accent, semantic color used sparingly. Not a literal recreation of
any shipping app.

Every token below ships as a named color in `App/Resources/Colors.xcassets`
with both a light and a dark value (`docs/decisions/0008-client-design-direction.md`'s
dark-mode revision) — the "Hex (dark)" column here is that variant.
`Palette.swift`'s Swift constants read the asset by name, so `ColorScheme`
resolution happens automatically; no view branches on light/dark itself.

## Surfaces

| Token           | Hex (light) | Hex (dark) | Swift name              | Use                          |
| ---------------- | --------- | --------- | ------------------------ | ----------------------------- |
| Background       | `#F2F5F3` | `#000000` | `Palette.background`     | Screen background — a barely-green neutral |
| Card              | `#FFFFFF` | `#1C1C1E` | `Palette.card`           | Card fill                      |
| Neutral fill      | `#E5E5EA` | `#2C2C2E` | `Palette.neutralFill`    | Icon tiles, dividers, tracks   |

## Hero band

The filled band behind Panoramica's hero figure (`HeroCard`). Its own
colorset, **not** `accent`: the dark accent is a light rose, so white text on
it would fail contrast. The band stays a deep plum in both appearances.

| Token           | Hex (light) | Hex (dark) | Swift name              | Use                          |
| ---------------- | --------- | --------- | ------------------------ | ----------------------------- |
| Hero fill        | `#532730` | `#451A24` | `Palette.heroFill`       | Hero band — top gradient stop  |
| Hero fill deep   | `#370D18` | `#2E0611` | `Palette.heroFillDeep`   | Hero band — bottom gradient stop |
| On hero          | `#FFFFFF` | `#FFFFFF` | `Palette.onHero`         | Text/figures on the band       |
| On hero (2nd)    | white 72% | white 72% | `Palette.onHeroSecondary`| Eyebrow/caption on the band    |

## Ink (text)

| Token       | Hex (light) | Hex (dark) | Swift name          | Use                                  |
| ----------- | --------- | --------- | -------------------- | -------------------------------------- |
| Primary     | `#1C1C1E` | `#F2F2F7` | `Palette.ink`        | Headlines, primary amounts             |
| Secondary   | `#6E6E73` | `#98989D` | `Palette.inkSecondary`| Labels, captions                      |
| Tertiary    | `#8E8E93` | `#6C6C70` | `Palette.inkTertiary` | Muted metadata (dates, counts)         |
| Quaternary  | `#AEAEB2` | `#48484A` | `Palette.inkQuaternary`| Non-counted amounts (transfers, etc.) |

## Accent

| Token          | Hex (light) | Hex (dark) | Swift name           | Use                                |
| -------------- | --------- | --------- | ---------------------- | ------------------------------------ |
| Accent         | `#582832` | `#D48F96` | `Palette.accent`       | Deep plum — links, primary buttons, positive net, active tab |
| Accent pressed | `#461823` | `#B6737B` | `Palette.accentPressed`| Pressed/hover state                  |
| Accent tint    | `#FEECEE` | `#2F1D20` | `Palette.accentTint`   | Pale brand wash — active filter token, card eyebrow, period strip |

`#582832` is a warm-dark plum ("prugna / testa di moro") — AAA on white
(11.9:1). The dark accent is a luminosity-raised warm rose, not an opacity
flip. The brand is deliberately **not** a green any more: a green accent
collided with `income` / the `green` data tone (`#248A3D`), both green, and
sat awkwardly among the ten data tones. The one pairing to keep an eye on now
is the **dark** accent (`#D48F96`) versus the dark `pink` data tone
(`#E698B5`) — close in luminance, apart in hue, and they never share a
surface (accent is chrome, `pink` is a category glyph), the same kind of
caveat forest carried against `income`.

The underlying asset is named `AccentColor`, not `Accent`: it doubles as the
target's global accent color (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`
in `client/Project.yml`, so tint system controls pick it up automatically), so
`Palette.accent` reads that one asset rather than keeping a second colorset
in sync by hand.

Accent history: Apple system indigo `#5856D6` / `#7D7AFF` until 2026-09-06 →
petrol green `#0E7C86` / `#33B7BE` for one day → forest green `#1B5E3F` /
`#58BF95` (2026-09-07) → deep plum `#582832` / `#D48F96` (2026-09-08). The
indigo hex still exists as the `indigo` data tone below — decoupled from
accent.

## Semantic

**Spending stays in ink, never red.** This is the rule most likely to get
violated by accident — a spend row uses `Palette.ink`, not a red. Red is
reserved for category iconography only (e.g. a restaurant icon tile), never for
an amount.

| Token         | Hex (light) | Hex (dark) | Swift name              | Use                                   |
| ------------- | --------- | --------- | ------------------------ | ---------------------------------------- |
| Income        | `#248A3D` | `#30D158` | `Palette.income`         | Positive amounts (salary, reimbursement) |
| Income tint   | `#E2F7E6` | `#0F2A17` | `Palette.incomeTint`     | Income icon tile background              |
| Warning       | `#C2660A` | `#FF9F0A` | `Palette.warning`        | Consent-expiry banner icon               |
| Warning ink   | `#8A4B08` | `#FFB454` | `Palette.warningInk`     | Consent-expiry banner title text (`warning` itself is too low-contrast for small bold text on `warningTint`) |
| Warning tint  | `#FFF1DE` | `#3A2410` | `Palette.warningTint`    | Consent-expiry banner background         |
| Warning border| `#FFD8A8` | `#6B4A1E` | `Palette.warningBorder`  | Consent-expiry banner border             |
| Status dot    | `#FF9500` | `#FF9F0A` | `Palette.statusWarn`     | Connection status dot (expiring soon)    |
| Category red  | `#D70015` | `#FF453A` | `Palette.categoryRed`    | Category icon only — never an amount     |
| Category red tint | `#FFEDEC` | `#3A1210` | `Palette.categoryRedTint`| Category icon tile background        |

`net` in the dashboard hero carries `Palette.accent` when positive (the only
place accent doubles as a semantic color, because `net` is the one genuinely
signed figure — see ADR 0007).

## Category donut and breakdown list

The dashboard's "Per categoria" donut and full-width breakdown list
(`docs/design/canvas/Main.dc.html`, unblocked once `GET /dashboard/summary`
started returning `by_category` — `docs/decisions/0007-dashboard-aggregation.md`'s
"Revisit when"). **Per-category, not rank-based**: since the 2026-08-26
revision of ADR 0008, a segment and its matching breakdown row use the
category's own `PaletteColor` (`Palette.color(_:)`, the same ten-tone
vocabulary `IconTile` already draws from — ADR 0017) rather than a color
assigned by sorted position. The earlier rank-based rotation
(`Palette.categoryChart1..5`/`categoryChart(rank:)`) is retired along with the
position-paired legend it existed for — a category's color no longer shifts
between periods if its rank does, and an uncategorized/uncolored entry falls
back to `Palette.color(.slate)`, same default `IconTile` uses everywhere else.
The donut's background ring still reuses `Palette.neutralFill`, same track as
every other chart on this screen.

## Trend bars

The dashboard's trend chart (`docs/design/canvas/Main.dc.html`'s "Spesa
giornaliera", badge removed once `by_day` shipped —
`docs/decisions/0007-dashboard-aggregation.md`'s 2026-08-25 revision; renamed
`by_bucket` in the third revision; scrubbable across day/week/month buckets,
`BucketBarsChart`, in ADR 0008's 2026-08-26 revision). No new tokens: the
fill reuses `Palette.accent` (dimmed to ~0.35 on every bar but the one
currently scrubbed/selected, same convention `DonutChart` uses for its own
selection) and the track reuses `Palette.neutralFill`, same as the donut's
own track.

## Appearance tokens

The account and category colour/icon picker (ADR 0017, extended to categories
by ADR 0018). **User-chosen and persisted per entity**, not assigned by rank
or sorted position — a `PaletteColor` survives regardless of how a list
re-sorts, which is exactly why the dashboard donut/breakdown list above draws
from this same vocabulary rather than its own rank-based one. Each of the ten
tones ships as **one** colorset (`PaletteColor<Name>`, the tile fill) with an
explicit dark variant — see `IconTile.swift`. There was a paler
`PaletteColor<Name>Tint` counterpart per tone until the 2026-09-08 tone
revision, when `IconTile` — its only consumer — moved to a solid fill with a
white glyph; the tint colorsets and `Palette.tint(_:)` went with it.

The **light** values were rebuilt in that revision on one perceptual model:
luminosity levelled across the tones and chroma equalized (raised toward
Apple's own saturation, but consistent so ten tones read as one family rather
than ten unrelated system colours). A thin coloured glyph on a pale tile read
as muddy at row size — the colour now carries as a full 32pt fill with a white
`.semibold` glyph, which is where the saturation reads. Dark values are
unchanged from the 2026-08-25 dark-mode revision.

| Token   | Hex (light) | Hex (dark) | Swift name (`Palette.color(_:)`) | Wire value |
| ------- | --------- | --------- | ----------------------------------- | ---------- |
| Blue    | `#4687DB` | `#409CFF` | `.color(.blue)`   | `blue`   |
| Indigo  | `#7D77D9` | `#7D7AFF` | `.color(.indigo)` | `indigo` |
| Purple  | `#A569C2` | `#BF5AF2` | `.color(.purple)` | `purple` |
| Pink    | `#C85C89` | `#FF9EC0` | `.color(.pink)`   | `pink`   |
| Red     | `#CF5E55` | `#FF453A` | `.color(.red)`    | `red`    |
| Orange  | `#C96726` | `#FF8F66` | `.color(.orange)` | `orange` |
| Amber   | `#B48701` | `#FFC53D` | `.color(.amber)`  | `amber`  |
| Green   | `#009F63` | `#30D158` | `.color(.green)`  | `green`  |
| Teal    | `#0096AE` | `#4DC8DB` | `.color(.teal)`   | `teal`   |
| Slate   | `#7E8792` | `#6C6C70` | `.color(.slate)`  | `slate`  |

`slate` is the neutral default for anything the user has not deliberately
coloured yet.

Icons are a fixed SF Symbol map per entity, kept in `App/Sources/DesignSystem/
IconTile.swift` (`AccountIcon.systemImageName`) rather than on the wire enum —
the backend has no notion that SF Symbols exist (ADR 0017).

## Separators and elevation

| Token             | Value                              | Use                        |
| ------------------ | ----------------------------------- | ---------------------------- |
| Separator (subtle) | `rgba(60,60,67,.06)`                | Card border                  |
| Separator (visible)| `rgba(60,60,67,.08)`–`.12`          | Dividers, stat separators    |

Three elevation levels since the 2026-09-08 tone revision (`CardElevation` /
`View.cardElevationShadow(_:)` in `Card.swift`) — one card and one shadow
everywhere was part of what read as unfinished:

| Level      | Shadow                                                          | Radius | Use                                        |
| ---------- | -------------------------------------------------------------- | ------ | ------------------------------------------- |
| `.flush`   | none — leans on the border                                            | `Radius.row` (16)  | A group nested inside another card |
| `.resting` | one soft layer: `radius 10, y 4, black .05`                           | `Radius.card` (20) | The everyday card — the new default |
| `.raised`  | two layers: `radius 1, y 1, black .04` + `radius 14, y 8, black .22`  | `Radius.card` (20) | Something that genuinely floats — `HeroCard`, an active sheet |

`Palette.cardShadow` is **opaque** `Color.black`; each level's modifier carries
the opacity. `.raised` keeps the deep two-layer recipe that used to be on every
`Card` (it once also carried its own `.opacity(0.16)`, multiplied again by the
modifiers — the far shadow rendered at ~1/14 strength and cards dissolved into
the background; that bug is fixed). If a level reads heavy on device, tune the
modifier in `Card.swift`, not a token.

**Dark mode**: `separator`/`separatorSubtle` stay a low-opacity overlay of
`Palette.ink` rather than gaining their own asset — `ink` itself is
near-black in light mode and near-white in dark mode, so the same `.opacity`
call reads as a soft dark line in one appearance and a soft light line in the
other, no separate dark value to keep in sync. `cardShadow` stays pure
`Color.black` in both appearances; a black drop shadow is naturally
near-invisible on a dark card over a dark background, which is the correct
dark-mode look — `Card`'s `separatorSubtle` border (not its shadow) is what
defines a card's edge once the shadow stops reading.

## Radii

Named in Swift as `Radius.<name>` (`App/Sources/DesignSystem/Radius.swift`,
added alongside `Spacing` in ADR 0017 — these values already existed as bare
literals at each call site; adopted in new/rewritten views only, the rest is
a tracked cleanup in `tasks/backlog.md`).

| Element        | Radius | Swift name    |
| -------------- | ------ | ------------- |
| Card           | 20     | `Radius.card` |
| Row            | 16     | `Radius.row`  |
| Icon tile      | 12     | `Radius.tile` |
| Pill / chip    | 999 (fully rounded) | `Radius.pill` |

## Typography

- System font (SF Pro via SwiftUI `.system`), not a custom typeface.
- **Tabular figures on every amount** — `AmountText` (the shared component)
  bakes this in; never render a bare `Text` for a money value.
- Build sizes relative to a `Font.TextStyle` (`.system(.title, design: .default)`
  or `.system(size:weight:relativeTo:)`), not fixed points — Dynamic Type is a
  day-one requirement per ADR 0008, not a follow-up.
- Weight scale used across the canvas: regular (400) body text, semibold (600)
  labels and secondary figures, bold (700) headlines and primary amounts.
- **The designed figure treatment** (2026-09-08 tone revision): `AmountText`
  renders the `",dd"` cents as a separate run. For a spend or a non-counted
  leg the cents take a receded ink tone (`inkTertiary` / `inkQuaternary`) so
  the whole units read first; income and positive net keep the tail the
  figure colour, since a grey tail on a green number reads as broken. A large
  protagonist figure (the dashboard hero) also passes a smaller `fractionFont`
  and a slight negative `tracking`. The split is display-only — VoiceOver
  still gets the whole formatted figure via `accessibilityLabel`. Italian
  formatting only: the split keys off a trailing `","` + two digits and falls
  back to one run for any other shape.

## Text never wraps

A row, badge, chip, or any label that shares a line with siblings is
**single-line with an explicit truncation policy** — a second line makes a
list ragged and is nearly always worse than an ellipsis. Concretely:

- A **fixed-width tag** (`Badge`, `FilterChip`) carries
  `.lineLimit(1).fixedSize(horizontal: true, vertical: false)` so it keeps its
  intrinsic width and a flexible sibling truncates instead of it. This only
  works when there **is** a flexible sibling to give: in a row where every item
  is `.fixedSize`, nothing yields, so the row reports a minimum width equal to
  the sum of all intrinsic widths and forces its container wider — off the
  screen if the labels are long enough (the dashboard category ribbon's legend
  hit exactly this). A row of unavoidably-fixed items belongs in a horizontal
  `ScrollView` (next bullet); a row that must fit uses `.layoutPriority` to pick
  which label truncates first, not `.fixedSize` on all of them.
- A **flexible label** in a row (a transaction description, a caption) carries
  `.lineLimit(1)` and is the element that gives — it truncates with the
  default tail ellipsis.
- A **row of tags that can outgrow the width** (Movimenti's filter chips)
  goes in a `ScrollView(.horizontal, showsIndicators: false)` with
  `.scrollClipDisabled()`, not an `HStack` that compresses or wraps.
- A control that toggles into a row (the transfer-pairing checkbox)
  **replaces** an existing element of the same footprint rather than being
  inserted beside one — inserting shifts every sibling and forces a wrap.

Multi-line is fine for a standalone paragraph (an `EmptyState` description, a
card's explanatory sentence) — the rule is about anything laid out in a line
with other things.

## Spacing

Named in Swift as `Spacing.<name>` (`App/Sources/DesignSystem/Spacing.swift`,
ADR 0017) — same adoption posture as `Radius` above.

| Token              | Value | Swift name           |
| ------------------- | ----- | --------------------- |
| Screen gutter        | 20    | `Spacing.gutter`      |
| Gap between cards    | 16    | `Spacing.cardGap`     |
| Card internal padding| 20    | `Spacing.cardPadding` |
| Row internal padding | 9     | `Spacing.rowPadding`  |

## History

The first canvas iteration (2026-08-22) used a warm off-white background
(`#F8F7F4`), a periwinkle-violet accent (`#5B4FE0`), and Space Grotesk as the
typeface. On review the palette and font read as generic "AI product" rather
than native-feeling, so both were replaced with the Apple-native values above:
system font, cooler neutral background, and Apple's system indigo as the
accent (distinctive without being a made-up brand color). The category-chart
palette (blue/amber/orange/pink used in the "Concept" donut) was left
unchanged at the time — it is a functional categorical palette, not part of
the app's tone. **Settled 2026-08-24** once the category-breakdown backend
item shipped, with a rank-based five-color rotation and the two corrections
made to the canvas's warm off-palette track and grey — since retired in favor
of per-category color (see the 2026-08-26 entry below and "Category donut and
breakdown list" above).

**Dark mode added 2026-08-25** (`docs/decisions/0008-client-design-direction.md`'s
dark-mode revision, part of the M3 iPhone-trial roadmap's item 6): every
token above moved from a hardcoded `Color(hex:)` literal in `Palette.swift`
to a named color in `App/Resources/Colors.xcassets` with an explicit dark
appearance. Dark values follow Apple's own dark system-color choices where a
direct counterpart exists (accent, income, warning, category red all reuse
Apple's dark `systemIndigo`/`systemGreen`/`systemOrange`/`systemRed`), and a
luminosity-raised version of the light hex elsewhere (ink scale, category
chart rank colors) — never a straight opacity-flip of the light value, which
tends to read muddy on a near-black background.

**Appearance tokens, `Spacing`, and `Radius` added 2026-08-25** (ADR 0017,
the account alias/colour/icon slice of the "Daily driver, davvero"
milestone): ten new colour tones for the account (and, later, category)
picker, each with a paler tint for an icon tile background; `Spacing`/`Radius`
give the gutter/card/row/tile values from this file's own tables a Swift
name for the first time.

**Category chart retired for per-category color, 2026-08-26** (ADR 0008's
interactive-charts revision, Task 5 of the "Daily driver, davvero"
milestone): the rank-based `Palette.categoryChart1..5`/`categoryChart(rank:)`
rotation and its five colorsets are deleted — a category's donut segment and
breakdown-list row now draw from its own `PaletteColor` (the "Appearance
tokens" section above), the same token ADR 0017/0018 already made every
category carry. See "Category donut and breakdown list" above.

**Accent moved from indigo to petrol green, 2026-09-06** (ADR 0008's accent
revision, Fase B of the "Bella e affidabile" milestone). The brand accent
changed from Apple system indigo `#5856D6` / `#7D7AFF` to petrol green
`#0E7C86` / `#33B7BE` (pressed `#0A626B` / `#2A9CA3`), swapped in the
`AccentColor` / `AccentPressed` colorsets — the only code change, since every
call site reads `Palette.accent`. The owner found the indigo too close to a
generic "AI product" look after months of daily use. `PaletteColor.indigo`
(the data tone) is unchanged; accent and that tone are now separate colours.
A per-user accent picker in Settings was considered and parked
(`tasks/backlog.md`).

**Accent moved from petrol to forest green, 2026-09-07** (ADR 0008's Fase C
revision, "Bella e affidabile"). The petrol accent lasted a day; the owner
preferred a deeper, less teal green. `AccentColor` / `AccentPressed` /
`AccentTint` are now forest `#1B5E3F` / `#58BF95`, pressed `#124A31` /
`#3E9E78`, tint `#E8F2EC` / `#132A20`; the `HeroFill*` / `OnHero*` band
colorsets and a barely-green `#F2F5F3` background landed in the same pass,
along with the `Card` double-multiplied-shadow fix. The Accent and Hero
tables above carry the current values.

**Data palette harmonized, tiles filled, elevations, figure treatment,
2026-09-08** (ADR 0008's tone revision — the "darle un tono" pass). Four
changes, client-only, no backend:
- The ten `PaletteColor` **light** values rebuilt on one perceptual model
  (luminosity levelled, chroma equalized). Dark unchanged. See "Appearance
  tokens".
- `IconTile` anatomy → **solid fill + white glyph**; the ten
  `PaletteColor<Name>Tint` colorsets and `Palette.tint(_:)` deleted with it.
- **Three elevation levels** (`.flush` / `.resting` / `.raised`), `.resting`
  the new default. A Movimenti day group is now one card with hairline
  dividers instead of rows floating apart. See "Separators and elevation".
- **`AmountText` figure treatment** — receded cents, optional smaller
  fraction font and negative tracking on the hero. See "Typography".

**Accent → deep plum, Panoramica recomposed, 2026-09-08** (same tone
revision, second pass, after seeing the first on device):
- Accent forest green → **deep plum `#582832` / `#D48F96`**, `HeroFill*` to
  match, `scripts/gen-app-icon.swift` + `make icon` re-run. A green brand
  clashed with green income. See "Accent" and "Hero band".
- **Panoramica recompose**: the hero body drops its stat-columns section; the
  three secondary stats and the whole `ComparisonCard` collapse into one
  quiet `heroFootnote` caption line; the period strip loses the accent-tint
  block for a flush card. `ComparisonCard.swift` deleted.

Still owed (`tasks/backlog.md`): the on-device visual pass — light + dark +
Dynamic Type, every screen — and a `Spacing`/`Radius` sweep of
`DashboardView`.
