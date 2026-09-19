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

## Panoramica hero

A plain `Card` at `.raised` — still the only `.raised` card on the screen, so
the hierarchy is elevation- and scale-driven (`Typography.heroFigure`, 44pt,
tracking `-1.0`), not carried by a filled colour. The spend figure and every
label on the card are `ink`/`inkSecondary`/`inkTertiary`, same as any other
card. A `docs/decisions/0034-brand-triad.md` navy/lime/cream treatment
shipped here for one day (2026-09-16) and was withdrawn on-device
(`docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md`) — not
tuned, reverted; the color question is reopened, not decided. The `heroFill`
/ `heroFillDeep` / `onHero` / `onHeroSecondary` colorsets and `AmountText.Tone`
from the 2026-08-25→2026-09-08 revisions below stay removed too — this
section has now gone flat-white twice for two different reasons (dose, then
withdrawal), which is itself a signal that any future color treatment here
should be settled carefully, not shipped as a single-file experiment.

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
| Accent         | `#087ED7` | `#6FB4F3` | `Palette.accent`       | Bright azure blue — links, primary buttons, positive net, active tab |
| Accent pressed | `#0368B4` | `#5398D5` | `Palette.accentPressed`| Pressed/hover state                  |
| Accent tint    | `#EAF4FF` | `#132435` | `Palette.accentTint`   | Pale brand wash — active filter token only |

`#087ED7` is a bright azure — 4.2:1 on white, in Apple `systemBlue` territory (the owner asked for it lighter twice). It sits close to the `blue` data tone (`#4687DB`) in lightness now; they stay apart by chroma (the accent is markedly more saturated) and never share a surface. The dark accent is a
luminosity-raised sky blue. Deliberately distinct from the `blue` data tone
(`#4687DB`, a lighter mid-azure): the accent is deeper and more saturated, a
~2:1 luminance step between them. Not periwinkle/indigo — that hue was the
original "generic AI product" rejection and is still the `indigo` data tone.
The one pairing to keep an eye on is the **dark** accent (`#6FB4F3`) versus
the dark `blue` data tone (`#88B5F2`) — close in luminance, and they never
share a surface (accent is chrome, `blue` is a category glyph).

### Accent dosage

Five different accent hues were rejected inside three days (indigo → petrol →
forest → plum → cobalt → azure). The variable that kept failing was never the
hue — it was how much surface the accent covered. The rule, since the
2026-09-08 "dose, non tinta" revision:

- **The accent marks what you touch, or what is currently selected** — a
  button, a link, an active filter chip, the active tab, the segmented
  picker's selection, a pressed state. Nothing else.
- **Never a large filled surface** — no bands, headers, hero gradients, or
  tinted slabs behind a card. `accentTint` is for an active filter token, not
  a heading background.
- **Never a heading** — a card eyebrow / section title is `Palette.ink`, not
  the accent.
- **Never navigation chrome** — period chevrons, back arrows, disclosure
  chevrons are `inkSecondary` / `inkTertiary`.
- **At most one primary CTA per screen** carries the filled accent.
- **Meaning comes from the data, not from chrome.** A category or account
  figure takes its own `PaletteColor`; a semantic figure (income, a positive
  net) takes `Palette.income`. The accent is not a semantic colour.
- If a screen looks flat without a block of colour, the fix is hierarchy —
  elevation, type scale, whitespace — not a coloured rectangle. `Conti` is
  the reference: it has no band and no accent surface, and it is the screen
  the owner calls the cleanest.

`docs/decisions/0034-brand-triad.md` (2026-09-16) narrowed this rule for one
day to let a screen's designated `.raised` protagonist surface carry a brand
colour instead of white; withdrawn on-device the next day
(`docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md`) — see
"Panoramica hero" above. The rule above is back to unqualified: a data row, a
list, a heading, navigation chrome, and every card without exception never
carry a filled colour, brand or accent.

`net` in the dashboard hero no longer carries the accent when positive — it
is `Palette.income`, like every other positive figure (`AmountText.Kind.net`).

The underlying asset is named `AccentColor`, not `Accent`: it doubles as the
target's global accent color (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`
in `client/Project.yml`, so tint system controls pick it up automatically), so
`Palette.accent` reads that one asset rather than keeping a second colorset
in sync by hand.

Accent history: Apple system indigo `#5856D6` / `#7D7AFF` until 2026-09-06 →
petrol green `#0E7C86` for one day → forest green `#1B5E3F` / `#58BF95`
(2026-09-07) → deep plum `#582832` (2026-09-08, ~half a day) → cobalt blue
`#025BAD`, brightened to `#056DB8` → **bright azure `#087ED7` / `#6FB4F3`**
(2026-09-08, current). The indigo hex still exists as the `indigo` data tone
below — decoupled from accent. After the fifth swap the conclusion was that
the hue was not the problem (see "Accent dosage" above); the azure stays and
gets re-judged on device *after* the dose came down, not before.

## Semantic

**Spending stays in ink, never red.** This is the rule most likely to get
violated by accident — a spend row uses `Palette.ink`, not a red. Red is
reserved for category iconography only (e.g. a restaurant icon tile), never for
an amount.

| Token         | Hex (light) | Hex (dark) | Swift name              | Use                                   |
| ------------- | --------- | --------- | ------------------------ | ---------------------------------------- |
| Income        | `#248A3D` | `#30D158` | `Palette.income`         | Positive amounts (salary, reimbursement) |
| Warning       | `#C2660A` | `#FF9F0A` | `Palette.warning`        | Consent-expiry banner icon               |
| Warning ink   | `#8A4B08` | `#FFB454` | `Palette.warningInk`     | Consent-expiry banner title text (`warning` itself is too low-contrast for small bold text on `warningTint`) |
| Warning tint  | `#FFF1DE` | `#3A2410` | `Palette.warningTint`    | Consent-expiry banner background         |
| Warning border| `#FFD8A8` | `#6B4A1E` | `Palette.warningBorder`  | Consent-expiry banner border             |
| Status dot    | `#FF9500` | `#FF9F0A` | `Palette.statusWarn`     | Connection status dot (expiring soon)    |

`net` in the dashboard hero is `Palette.income` when positive and
`Palette.ink` otherwise (`AmountText.Kind.net`). It used to take `Palette.accent`
when positive; the 2026-09-08 "dose, non tinta" revision dropped that — the
accent is not a semantic colour (see "Accent dosage").

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
`BucketBarsChart`, in ADR 0008's 2026-08-26 revision). No new tokens. Since
the 2026-09-08 "dose, non tinta" revision the bars are a muted `Palette.ink`
at `.opacity(0.16)` at rest — only the bar currently scrubbed/selected turns
`Palette.accent` (a chart-wide blue fill was exactly the accent over-use that
revision pulled back). The track reuses `Palette.neutralFill`, same as the
donut's own track.

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

**`EventTile`** (ADR 0027) is the exception to "solid fill + white glyph". An
event's identity is a free-text `emoji` plus an optional `PaletteColor`, so
the tile has two anatomies: with an emoji, the glyph sits on a **pale wash**
of the colour — `Palette.color(...)` at `0.16`, a `0.32` hairline border —
because an emoji is its own colour and would be unreadable on a saturated
fill (the tone revision's "muddy" finding was about a *thin coloured stroke*,
which this is not); with no emoji, it falls back to a plain `IconTile`
(`calendar`, solid fill, white glyph). The opacity rides on an already
theme-dynamic colour, so it resolves in both appearances without a separate
dark value — the `Palette.separator` technique.

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
| `.raised`  | two layers: `radius 1, y 1, black .04` + `radius 14, y 8, black .22`  | `Radius.card` (20) | Something that genuinely floats — Panoramica's hero card, an active sheet |

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
defines a card's edge once the shadow stops reading. The dark `Background`
was raised from pure `#000000` to `#0B0B0C` in the 2026-09-08 "dose, non
tinta" revision — a hair off black so a `#1C1C1E` card still has an edge
against it. Revert to `#000000` if cards read flat on device.

## Glass

Liquid Glass (`docs/decisions/0030-liquid-glass-chrome.md`), adopted since the
deployment target moved to iOS 26 / macOS 26. **Glass marks chrome anchored
to a screen edge — the tab bar, a toolbar, a sheet's own bottom action bar —
never a content surface and never a control living inside a screen's
scrollable body**, narrowed to this position-based criterion by
`docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md` after
on-device use found the app's own apps never put glass on an in-body chip or
button, only on their own dock/toolbar. Two earlier, narrower exceptions were
tried and rejected the same way: the one `.raised` card per screen
(`docs/decisions/0032-glass-on-raised-cards.md` — a money figure read worse
on translucent material) and, now, every in-body control ADR 0030/0031
originally put in glass by component identity rather than position.
`Card` at every elevation, a list row, an `OptionListCard`, `Badge`,
`IconTile` — none of these carry glass, and neither does `PillButton`,
`FilterChip`, `IconButton`, or `SelectionSheet`'s closed control any more.

| Carries glass | Stays opaque |
| -------------- | ------------- |
| Tab bar (`.tabBarMinimizeBehavior(.onScrollDown)`, iOS only) | `Card` at every elevation (`.flush`/`.resting`/`.raised`) |
| Toolbars (native, automatic on iOS 26) | Every list row (Movimenti, day groups, `OptionListCard`) |
| Sheet bottom action bars (`.glassEffect(.regular, in: Rectangle())`, replacing `.regularMaterial`) — the Filtri sheet's "Applica" bar, Movimenti's transfer-selection bar | `PillButton`, the Filtri sheet's "Applica" button, `TrackingStartView`'s primary/secondary pair — flat `ActionButtonStyle`/hand-rolled fills (`ActionButtonStyle.swift`) since they live inside a screen, not at its edge |
| `.scrollEdgeEffectStyle(.soft, for: .all)` (the chrome's own edge effect, `ScreenChrome.swift`) | `FilterChip` — flat `Palette.card`/`Palette.accentTint` capsule with a hairline border |
| `.pickerStyle(.menu)`'s system-provided glass (`AccountKind`, 6 cases) | `IconButton` — flat `Circle().fill(background)`, `.pressable` for press feedback |
| | `SelectionSheet`'s closed control — a bordered `Palette.card` rectangle, the same idiom `OptionListCard` uses |
| | `TransferSuggestionCard`'s "Ignora" button — flat `Palette.neutralFill` capsule |
| | `DisclosureChevron` — chrome-coloured (`inkQuaternary`) but opaque, no glass |
| | Panoramica's period strip (prev/next + unit picker) — a flush-styled opaque surface, glass tried and reverted (ADR 0032) |

Every sheet still gets its action bar and toolbar via
`.sheetChrome(_:detents:)` (`SheetChrome.swift`) — no sheet is left with a
flat full-height presentation since the 2026-09-15 coherence pass; what
changed is only the button drawn *inside* each bar.

If a screen reads flat, the fix is hierarchy — elevation, type scale,
whitespace — never a translucent content surface; `Conti` is the reference.

**Motion**: a row pushing to its detail screen zooms from the row's own
frame instead of sliding in — `TransactionRow` → `TransactionDetailView`,
`EventsView`'s row → `EventDetailView` (`.matchedTransitionSource` +
`.navigationTransition(.zoom(sourceID:in:))`, iOS only —
`ZoomNavigationTransition` is unavailable on macOS, so the destination gets
the system's default push there). SwiftUI backs off to a plain push under
Reduce Motion automatically; no extra handling needed, same as the rest of
this file's motion (`AmountText`'s digit-roll, `SkeletonBlock`'s shimmer).
A `GlassEffectContainer` around the Movimenti toolbar's "•••"/filtri/"+"
cluster was considered and dropped: native `ToolbarItem`s already merge and
separate their own glass on iOS 26, so wrapping them again would be inert.

**Coherence sweep (2026-09-15)**: the same zoom transition extends to every
row→detail push in the app, not just Movimenti/Eventi —
`AdvancesView`'s person row → `PersonDetailView`, its advance row and
`PersonDetailView`'s own advance row → `TransactionDetailLoader`, and
`TransactionDetailView`'s event chip → `EventDetailView`. Settings'
navigation rows (`SettingsView`) deliberately do **not** zoom — a plain list
row with a small leading icon has no visual frame worth zooming from, same
as Apple's own Settings app. Also found and fixed one real inconsistency at
the time: `TransferSuggestionCard`'s secondary "Ignora" button was a flat
`Palette.neutralFill` capsule sitting next to a glass `PillButton` — glass
briefly, back to its original flat capsule since
`docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md`. Checked
and deliberately left alone at the time: every other
`Palette.neutralFill` fill in the app (role glyphs, avatars, progress
tracks, the FX summary tile) is content/metadata, not a control — each
already carries a comment saying so.

**App icon**: `scripts/gen-app-icon.swift` (`make icon`) now renders three
iOS variants — light (unchanged, cyan→azure), dark (same hue family, pulled
down in luminosity so it doesn't glow next to the other dark Home Screen
icons), and tinted (fully grayscale, per Apple's own requirement — the
system multiplies its own colour on top). Declared in
`AppIcon.appiconset/Contents.json` via the classic flat-PNG `appearances`
extension (iOS 18+), not the newer layered Icon Composer format — `make icon`
stays the one source of truth.

**Picking a picker.** Two shapes, chosen by what the options are:

- **Data-backed options that carry their own icon and colour** (accounts,
  categories) → `SelectionSheet` (`App/Sources/DesignSystem/SelectionSheet.swift`),
  opening an `OptionListCard`/`OptionRow` list (`OptionList.swift`) — a bare
  `Picker`'s closed control shows neither the icon nor the colour.
- **A small, static, closed enumeration** (`AccountKind`, 6 cases) → a native
  `Picker` styled `.menu`, with `Label(_, systemImage:)` per option instead of
  a bare `Text` — the icon comes along for free in both the open menu and the
  closed control, and the whole thing renders in Liquid Glass automatically
  on iOS 26. No need for `SelectionSheet`'s own sheet-and-card machinery when
  there is no per-option colour to show and the list is short enough for a
  dropdown.

`Palette.backgroundElevated`: a barely-there neutral gradient over
`Palette.background` (light `#F2F5F3 → #FAFBFA`, dark `#0B0B0C → #151517`),
applied via `View.screenBackground()`. It exists only so the chrome's glass
has something to refract — it carries no hue, so it is not a reprise of the
accent-band rejections above. `Palette.background` itself is unchanged and
still used wherever a flat fill is wanted (behind a sheet's content, the
launch screen).

**Coherence pass (2026-09-15, `docs/decisions/0031-visual-coherence-pass.md`)**:
the Liquid Glass batch above had only touched Movimenti's own toolbar and
filter sheet; this pass applies the same chrome uniformly to every screen
and sheet, closing the gap that made Panoramica in particular read flat
(zero glass, a stock `.segmented` `Picker`) next to Movimenti. Nothing in
the "carries glass / stays opaque" table above changed rule — only reach.

## Screen chrome

`View.screenChrome(_ title:, style:)` (`ScreenChrome.swift`) is the one
place a screen's background, nav title, and display mode are decided —
replacing 33 call sites that each wired `.screenBackground()` +
`.navigationTitle(_:)` separately, with the four tabs' display modes
disagreeing (Panoramica alone `.inline`).

- `.tabRoot` — Panoramica, Movimenti, Conti, Impostazioni: a large title
  that collapses to inline on scroll, plus `.scrollEdgeEffectStyle(.soft,
  for: .all)` so the chrome's glass has an edge effect to react to at the
  screen's own top/bottom, not just the tab bar and toolbar. Matches every
  stock Apple top-level list (Impostazioni, Mail, Musica).
- `.pushed` (the default) — every screen reached by a push (Eventi,
  Anticipi, Categorie e regole, Inizio tracciamento, any detail screen):
  inline throughout, same as a stock app's own drill-down. **Deliberately
  not large everywhere** — a large title on a pushed detail screen would
  fight its content for protagonist billing and break the convention
  `PersonDetailView` already followed.

Panoramica moved from `.inline` (the 2026-09-08 "dose, non tinta" call, so
the hero figure alone carried the top) to `.tabRoot`'s large/collapsing
title, for consistency with the other three tabs. Owed on-device judgment
(`tasks/backlog.md` item 13): if the title fights the hero figure, this
reverts to `.pushed` and every tab follows, recorded in ADR 0031 rather
than left to drift again.

## Sheet chrome

`View.sheetChrome(_ title:, detents:)` (`SheetChrome.swift`): the
background gradient, an inline title (a sheet is a focused task, not a
place worth a large one), `.medium`/`.large` presentation detents, and a
visible drag indicator — applied to the content inside a sheet's own
`NavigationStack`, next to `.toolbar`. Before the 2026-09-15 coherence pass
only `SelectionSheet` and `TransactionFiltersSheet` had detents or a drag
indicator; the other 15 sheets were full-height with no resize affordance.
All 17 now share this.

Four picker-shaped sheets that hand-rolled `Card` + `Divider` rows moved to
`OptionListCard`/`OptionRow` (`EventPickerSheet`, `CreateRuleSheet`'s
category list, `AddReimbursementSheet`'s participant list), the same
component "Picking a picker" above already names for
`TransactionFiltersSheet`/`SelectionSheet`. `EventPickerSheet` needed a
leading `EventTile` (an emoji wash, ADR 0027) rather than `OptionRow`'s
`IconTile`/swatch pair, so the shared row skeleton — title, trailing
checkmark, `.pressableRow` — was factored out as `OptionRowLayout`, generic
over its leading glyph. `AddEventMembersSheet`'s candidate list stays
custom: it is a tap-to-add-immediately list with a trailing amount, not a
single-selection picker, so `OptionRow`'s checkmark semantics don't fit.

`LabeledField` (`EyebrowLabel` + `TextField`/`SecureField`, `LabeledField.swift`)
replaces the hand-rolled version of the same three lines
(`.font`/`.foregroundStyle(Palette.ink)`/`.autocorrectionDisabled()`) at
~10 call sites — a name, an amount, a currency code, each in its own
`Card`. Not for a dense multi-field card (Settings' Server card keeps its
own smaller caption-label layout).

## Loading and press feedback

- **Skeletons, not spinners.** A screen that is still loading draws a rough
  silhouette of what is coming — `SkeletonBlock` (a `Palette.neutralFill`
  rounded rect with a slow shimmer, a no-op under Reduce Motion) assembled
  into `DashboardSkeleton` / `ListSkeleton` (`App/Sources/DesignSystem/
  Skeleton.swift`). Added in the 2026-09-08 "dose, non tinta" revision; the
  three bare `ProgressView()`s on Panoramica / Movimenti / Conti are gone.
- **Press feedback on tappable rows and cards.** `PressableButtonStyle`
  (`.pressable` for a standalone card, `.pressableRow` for a full-bleed list
  row) — a small scale-down plus a faint `ink` veil while pressed, springing
  back. Replaces a bare `.buttonStyle(.plain)`; pairs with the
  `.sensoryFeedback` haptics that were already there. Not the accent — a
  press is still chrome.
- **Figures animate.** `AmountText` carries
  `.contentTransition(.numericText(value:))`, so a figure that changes while
  its view stays alive rolls its digits instead of snapping. On Panoramica
  the `stateTag` folds in the headline spend total, so a period change lands
  inside an animation transaction.

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

A pill or chip (`PillButton`, `FilterChip`) is fully rounded via SwiftUI's
`Capsule()` shape directly, not a numeric radius — there was a
`Radius.pill = 999` token for this, but it had zero call sites (`git log -S`)
and was removed 2026-09-18.

## Typography

- System font, `design: .rounded` (SF Pro Rounded) since
  `docs/decisions/0034-brand-triad.md` — still a SwiftUI `.system` font, not
  a custom typeface or a bundled dependency; every `Typography` token moved
  together, figures included, so the voice doesn't mix rounded and sharp
  cuts on the same screen.
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

| Token                | Value | Swift name              |
| --------------------- | ----- | ------------------------ |
| Screen gutter          | 20    | `Spacing.gutter`         |
| Gap between cards      | 16    | `Spacing.cardGap`        |
| Card internal padding  | 20    | `Spacing.cardPadding`    |
| Row internal padding   | 9     | `Spacing.rowPadding`     |
| Item gap               | 12    | `Spacing.itemGap`        |
| Tight gap              | 8     | `Spacing.tightGap`       |
| Card section gap       | 14    | `Spacing.cardSectionGap` |

**2026-09-15 sweep** (ADR 0031): 27 bare `.padding(20)` call sites moved to
`.padding(Spacing.gutter)` and 24 `VStack(spacing: 16)` stacks-of-cards moved
to `Spacing.cardGap`, closing the rest of `tasks/backlog.md` item 14. Left as
literals at the time, deliberately: values with no matching token, rather
than forced into the wrong one or given a one-off token for a single call
site — a colour swatch's 3pt corner and the two literals `tasks/backlog.md`
already named (the hero's `HStack(spacing: 16)`, the FX tile's
`cornerRadius: 14`).

**2026-09-18 scale expansion**: `Spacing.itemGap` (12) and `Spacing.tightGap`
(8) name the app's two most-repeated bare `spacing:` values — 42 and 28 call
sites respectively, out of 158 total across 14 distinct values found in
`App/Sources`. `Spacing.cardSectionGap` (14) names `Card`'s own default
content spacing (`Card.swift`), previously a nude `spacing: 14` even though
every card in the app inherits it. The remaining eleven distinct values
(0, 2, 3, 4, 5, 6, 10, 16, 18, 20, 22, 24) stay bare literals: each is either
a true one-off (a swatch's 3pt corner) or a value that recurs but describes
several genuinely different gaps depending on call site (a compact row's
`6`, a text stack's `4`) rather than one repeated design decision — naming
them would force a false single meaning onto values that don't share one.
Revisit if a future screen's literal turns out to be the same decision
repeated, not a coincidence of arithmetic.

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

**Accent → blue, Panoramica recomposed, 2026-09-08** (same tone revision,
second pass, after seeing the first on device):
- Accent forest green → deep plum → **cobalt blue `#025BAD` / `#6DABEC`**
  (the plum lasted about half a day — "chemmerda pure sto colore"). `HeroFill*`
  to match, `scripts/gen-app-icon.swift` + `make icon` re-run each time. A
  green brand clashed with green income; blue is deeper and more saturated
  than the `blue` data tone, and is not the periwinkle that was rejected as
  "generic AI product". See "Accent" and "Hero band".
- **Panoramica recompose**: the hero body drops its stat-columns section; the
  three secondary stats and the whole `ComparisonCard` collapse into one
  quiet `heroFootnote` caption line; the period strip loses the accent-tint
  block for a flush card. `ComparisonCard.swift` deleted.

**"Dose, non tinta" — hero band removed, accent dosage ruled, 2026-09-08**
(ADR 0008 revision). After a fifth accent swap (cobalt → **azure `#087ED7` /
`#6FB4F3`**) the owner still disliked the "main colour" — diagnosis: the
accent was on too much surface, not the wrong hue. Client-only:
- **Panoramica's hero band is gone.** `HeroCard.swift`, the `heroFill` /
  `heroFillDeep` / `onHero` / `onHeroSecondary` colorsets, and
  `AmountText.Tone` are deleted. The hero is a plain `Card` at `.raised`
  (the only one on the screen); `Typography.heroFigure` → 44pt, tracking
  `-1.0`; iOS navigation title → `.inline`.
- **"Accent dosage" rule** written into this file (see the section under
  "Accent"): the accent marks what you touch or what is selected, never a
  filled surface, a heading, or navigation chrome. Call sites bonified —
  `net` positive → `income`; `BucketBarsChart` bars → muted `ink`, accent
  only on the scrubbed bar; "Per conto" eyebrow, the transfer-suggestion
  card, `TransactionRow`'s role glyph, the advance split bar / avatars, the
  import "Nuovi" stat all off the accent.
- **Rifinitura**: skeletons replace the three bare spinners
  (`Skeleton.swift`); `PressableButtonStyle` on tappable rows/cards;
  `AmountText` rolls its digits (`.contentTransition(.numericText)`); tab
  bar icons gain filled variants (`chart.bar`, `list.bullet.rectangle.portrait`);
  dark `Background` `#000000` → `#0B0B0C`.
- **App icon**: `scripts/gen-app-icon.swift` gets its own `iconTop` /
  `iconBottom` / `launchBar` constants (no longer aliased to `heroFill`). The
  old navy gradient was the darkest icon on the home screen; the owner picked
  a bright cyan→azure wash `#22C7E8 → #0A84FF` (variant "C" of four rendered
  candidates), white bars. `launchBar` stays `Palette.accent` `#087ED7`.

Still owed (`tasks/backlog.md`): the on-device visual pass — light + dark +
Dynamic Type, every screen, now including the band-less Panoramica and the
new dark background — and a `Spacing`/`Radius` sweep of `DashboardView`.

**Glass narrowed to chrome-by-position, brand triad withdrawn, 2026-09-17**
(`docs/decisions/0035-glass-to-chrome-only-and-triad-withdrawn.md`, after
real daily use of the `feat/visual-coherence` branch). Two findings: Liquid
Glass on `PillButton`/`FilterChip`/`IconButton`/`SelectionSheet` read wrong
wherever they sat inside a screen's own content, not just at a screen edge —
"Glass" above is rewritten around that edge-vs-body criterion, and those four
components go back to the flat fills they had before ADR 0030 (a shared
`ActionButtonStyle` for the three identical accent-CTA shapes, each other
call site restored to its own pre-0030 look). And the 2026-09-16 brand
triad (`brandNight`/`brandLime`/`brandCream`) is withdrawn outright — see
"Panoramica hero" and "Accent dosage" above — not tuned or extended; the
color question beyond the accent is reopened with no default assumed.
`design: .rounded` typography is unaffected.

**Conti recompose · Panoramica stats card · Categorie one-CTA, 2026-09-19.**
Three independent fixes, client-only, no backend:
- **Conti**: the three dashed "Collega/Crea/Importa" cards move into two
  toolbar buttons (an upload icon, and a "+" `Menu` for the two add flows) —
  the first screen to lose the dashed-card idiom this file's glass section
  used to describe as Conti's own. A connection with exactly one account now
  collapses header+row into a single card, so the account name never repeats
  the connection header above it; a multi-account connection's rows show
  alias-or-kind ("Carta"/"Corrente") instead of the bank's own raw account
  name. Institution logos 40pt → 48pt, pinned to `Radius.row` rather than the
  proportional `size * 0.3`.
- **Panoramica**: `DashboardHeroFootnote` (a bare, `.lineLimit(1)`-truncated
  `HStack` on the background) and the loose FX/"totale non disponibile"
  caption both retire into `DashboardStatsCard`, a `.flush` `Card` directly
  under the `.raised` hero — one elevation step down keeps the hierarchy
  hero-first without a colour band. Nothing truncates now: the comparison
  line and the stats line each wrap on their own terms.
- **Categorie e regole**: the screen's three stacked accent `PillButton`s
  (a real "Accent dosage" violation — more than one primary CTA per screen)
  collapse to one: creation moves to a toolbar `Menu`, and "Applica regole"
  — the screen's only actual *commit* — is the sole surviving in-card accent
  action, rendered only once there's a rule to apply. Drag-and-drop
  reparenting reuses the exact dashed-border idiom Conti's cards just
  retired, for the "rendi principale" drop zone — the one place a
  provisional, dashed target is still the right shape.

Still owed (`tasks/backlog.md`): the on-device visual pass for all three,
same standing gap this file has tracked since 2026-09-08.
