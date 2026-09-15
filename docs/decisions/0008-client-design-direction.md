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

## 2026-08-25 revision: app icon and launch screen

Item 2 of the M3 iPhone-trial roadmap (`tasks/backlog.md`). `App/Resources/`
held only a `.gitkeep` before this — no icon, no launch screen — so the app
appeared with a blank default icon on the home screen. Generated
programmatically with a small CoreGraphics script (no external image tool
was available in this environment) rather than sourced from anywhere else:
an accent-to-accent-pressed diagonal gradient (`Palette.accent`/
`accentPressed`) behind three white ascending rounded bars, the same visual
language as `DailyBarsChart` (the dashboard's own daily-spending chart) —
the icon references the app's own UI rather than an unrelated glyph.

`App/Resources/Assets.xcassets/AppIcon.appiconset`: an edge-to-edge 1024
image for iOS (opaque, no alpha — the OS applies its own rounded-square
mask; alpha would also block a future App Store submission) and the classic
ten-size set for macOS (macOS does not support the single-image shortcut the
way iOS does — confirmed by an actool "unassigned child" warning on the
first attempt with the modern single-size Contents.json; macOS also
receives the shape itself, an inset squircle at Apple's Big Sur+ ~9% margin,
baked into the image with a transparent surround, since macOS does not mask
third-party icons). `LaunchMark.imageset` reuses the same bar glyph alone
(accent-colored, transparent background, 1x/2x/3x) as `UILaunchScreen`'s
`UIImageName`, over `UIColorName: Background` — both set in `Project.yml`'s
`info.properties`, not a storyboard.

One extra cleanup this surfaced: a separate `AccentColor` colorset (needed
for `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, which system controls
read for their tint) duplicated `Palette.accent`'s values and, generated as
a Swift asset symbol, collided with `Palette`'s own `Accent` colorset on the
same identifier (`.accent`) — actool's own warning name for it. Resolved by
deleting the now-redundant `Accent` colorset and pointing `Palette.accent`
at `AccentColor` directly, so the global accent color and the design
system's own accent are structurally the same asset, not two kept in sync
by hand. `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOLS: NO` also set
in `Project.yml`, since `Palette` reads every asset by string name and never
touches the generated symbols.

**Verified**: `xcodebuild` macOS clean build with zero warnings (the actool
"unassigned child" and asset-symbol-collision warnings from the first
attempt both confirmed gone). `CFBundleIconFile`/`CFBundleIconName` resolve
to `AppIcon` and `UILaunchScreen` is present in the built `Info.plist`, and
`Assets.car` compiled into the app bundle — checked directly rather than by
inference. `swift test` (225) and `make test-app` (121) unchanged, since
nothing here is logic. No screenshot of the running app, same reasoning as
every prior M3 client slice — the icon/launch-mark images themselves
(`App/Resources/Assets.xcassets/`) are safe to view directly, since they
carry no user data.

## 2026-08-26 revision: interactive charts, legend pattern retired

Task 5 of the "Daily driver, davvero" milestone — the dashboard donut and
"Spesa giornaliera" bars were the only two decorative-only,
`.accessibilityHidden(true)` visuals in the app; this is the first time
either becomes interactive.

**The donut is now tap-to-select**, backed by a pure hit test
(`TraccioCore.fraction(forPoint:in:)`/`segment(atFraction:in:)`, tested
without SwiftUI) rather than anything computed in the view — same split this
ADR's original decision already drew between drawing (`DonutChart`) and the
arithmetic behind it (`TraccioCore`). The selected segment gets a thicker
stroke and full opacity; every other segment dims to ~0.35; a
`.sensoryFeedback(.selection, trigger:)` haptic fires on change. The donut's
own color source changes too: it now draws each category's own `PaletteColor`
(ADR 0017/0018) instead of a rank-based rotation — see `docs/design/tokens.md`'s
"Category donut and breakdown list" for why that retires
`Palette.categoryChart(rank:)`.

**The position-paired side legend (`zip(segments, entries)`) is retired
outright**, replaced by `CategoryBreakdownList` — a full-width, expandable
list below the (now smaller, 116→96pt) donut, one row per
`TraccioCore.CategoryBreakdownRow`. A root with children gets a chevron to
expand them in place (ADR 0018's two-level hierarchy landing in the UI, not
just the aggregation); a row's body drills through to Movimenti pre-filtered
to that category and the period currently shown. The legend pattern itself —
pairing a chart's visual order to a side list by array position — is retired
as a rule for this codebase, not just this one chart: a `zip` of two
independently-filtered/sorted arrays is exactly the kind of implicit coupling
`.claude/rules/swift.md`'s "make illegal states unrepresentable" warns against
one array reordering out from under the other silently produced a
mismatched row.

**New accessibility rule: an interactive chart that stays
`.accessibilityHidden(true)` must have a textual, focusable, activatable
representation alongside it, not fewer capabilities than the chart it
represents.** Rendering the donut's *arcs* individually accessible was
considered and rejected — a circle sector has no natural focus order or
activation gesture VoiceOver users expect, and would still need the same
name/amount/percentage text a list row already carries for free.
`CategoryBreakdownList` **is** that representation: every row it renders is
already a real, tappable view (unlike the old legend, which was purely
decorative text), so nothing new had to be built to satisfy this — the rule
is written down here because a future chart (the scrubbable bucket bars, Task
6) must follow the same shape, not because this one needed extra work to
comply.

**Verified**: `swift test` (296, +21: `DonutHitTestTests`,
`CategoryBreakdownRowsTests`) and `make test-app` (156, +13:
`DashboardViewModelTests`, new — the view model's selection/expansion/
drill-through state had no dedicated test file before this slice). No
backend change, no `make openapi`. Manual: still needed before calling this
done — dark/light, Dynamic Type AX3/AX5 (a breakdown row must reflow rather
than truncate its amount), and VoiceOver reading each breakdown row's name,
amount, and percentage.

## 2026-08-26 revision: longer periods, a scrubbable trend chart, comparison, per-account

Task 6/6 of the "Daily driver, davvero" milestone — the last task, closing
that milestone out. Client-only, no backend change (Task 4 already shipped
everything `GET /dashboard/summary` needed: `granularity`, `tz`,
`compare_start`/`compare_end`, `by_account`).

**`MonthPeriod` becomes `CalendarPeriod{start, end, unit}`, one type for
month/quarter/year rather than three in parallel** — there is exactly one
client, so switching `unit` (the new Mese/Trimestre/Anno segmented control
next to the existing arrows) is far cheaper against a single type. `previous()`/
`next()` step by re-deriving "the period of this same unit containing
`start - 1 day` / `end`", the same generic technique `MonthPeriod` already
used for months, so it needed no new logic to also work for quarters and
years. `granularity` is a computed property on the period
(month→day, quarter→week, year→month) — coarse enough that a year view
renders 12 bars, not 365.

**Correcting the previous revision's own prediction**: the Task 5 revision
above said a future chart "must follow the same shape" as the donut
(`.accessibilityHidden(true)` plus a separate accessible list). The trend
chart does not, deliberately — a bar chart has an idiomatic VoiceOver
interaction a donut's sectors do not
(`accessibilityAdjustableAction`, swipe up/down to move the selection and
hear the bucket's date/amount/count), so `BucketBarsChart` (renamed from
`DailyBarsChart`) is accessible *itself* rather than needing a list built
alongside it. The rule from the previous revision still holds — an
interactive chart needs a real accessible representation — it just has two
valid shapes now, and a chart earns the simpler one when it has its own
natural adjustable interaction.

**Scrub-to-preview, tap-to-drill-through, same split as the donut's
tap-to-select**: `TraccioCore.bucketIndex(atFraction:count:)` (pure, tested)
maps a drag position to a bucket index; `BucketBarsChart` calls it on every
`DragGesture` frame to drive a floating tooltip (date, spending, transaction
count), and on release — only when the drag barely moved, so scrubbing to
read values never accidentally navigates — drills through to Movimenti for
that bucket's exact `[start, end)`. This is the payoff of Task 3 reusing
`list_transactions_in_period`'s own `coalesce(booked_at, value_date)`
expression for the client's period filter: the drill-through's `start`/`end`
and the bucket's own boundary are guaranteed to agree.

**Two new cards, closing out backend capability that shipped in Task 4 with
no client surface yet**: `ComparisonCard` renders `ComparisonSummaryResponse`
(now requested unconditionally — every `load()` sends
`compareStart`/`compareEnd` from `period.previous()`) — a signed delta with
its own two-color rule (warning red for more spending, accent for less),
deliberately not routed through `AmountText.Kind`, since none of its four
existing cases mean "spending changed versus another period" (`.net`'s
"accent when positive" is the wrong valence: a *positive* delta here means
spending went *up*, not up in the good sense `.net` implies for income).
`AccountBreakdownCard` renders `by_account` flat (accounts have no
hierarchy) with each account's own alias/colour/icon — closing the loop with
ADR 0017: an account's identity finally shows up on the dashboard, not just
Conti and Movimenti.

**Hero card's arrows plus the new segmented unit control replace the single
month title** — switching units jumps to *the current period of the new
unit* (this quarter, this year), not an attempt to preserve some
equivalent-length window around the old selection, since months, quarters,
and years don't align to make that a well-defined operation.

**Verified**: `swift test` (316, +20: `CalendarPeriodTests` replacing
`MonthPeriodTests`, `BucketScrubTests`, `SpendingBarsTests` replacing
`DailyBarsTests`, two new `CalendarDate.date(calendar:)` cases) and
`make test-app` (164, +8: `DashboardViewModelTests` gains unit-change,
granularity, time-zone, comparison-window, and bucket-drill-through cases).
No backend change, no `make openapi`. Manual: still needed — dark/light,
Dynamic Type, VoiceOver on the scrubber's adjustable action, and confirming
a year period renders 12 bars, not 365.

## 2026-09-06 revision: accent moved from indigo to petrol green

Fase B of the "Bella e affidabile" milestone. After months of daily use the
owner said the Apple system indigo accent (`#5856D6`) read as a generic "AI
product" colour — the same failure mode this ADR's original review caught in
the first canvas iteration's periwinkle, resurfacing on the "corrected"
value. Seven alternatives were compared on a scratch artboard of the design
canvas; the owner chose **petrol green**.

**The brand accent is now petrol green** — `#0E7C86` light / `#33B7BE` dark,
pressed `#0A626B` / `#2A9CA3`. The dark value is a luminosity-raised petrol
tuned by eye to stay legible on near-black without turning neon-cyan, per
this file's dark-mode revision convention.

**One code change**: the `AccentColor` and `AccentPressed` colorsets in
`App/Resources/Colors.xcassets`. Every call site already reads
`Palette.accent` / `Palette.accentPressed`, and the global-accent asset name
(`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`) is unchanged, so nothing
in Swift or `Project.yml` moved. `docs/design/tokens.md`'s Accent table and
History are updated.

**`PaletteColor.indigo` is untouched** (`#5856D6` / `#7D7AFF`). Accent and
that data tone happened to be the same colour; they are now independent. An
account or category can still be "indigo".

**A per-user accent picker was considered and rejected for now** — a curated
set would each need a hand-tuned dark pair and would have to dodge the
semantic colours (green = income, red = category icon, amber = warning),
which is real work for a single-user app that can commit to one colour.
Filed in `tasks/backlog.md` to revisit if one accent stops satisfying.

**Verified**: colorset JSON only — `make lint` / `swift test` /
`make test-app` unaffected (no code path changed). Manual: still needed —
every screen in light and dark, confirming the petrol reads on the dashboard
hero's positive `net`, the active tab, and primary buttons.

## 2026-09-07 revision: forest green, a coloured hero, and a shadow bug

Fase C of the "Bella e affidabile" milestone — the on-device pass Fase B
deferred surfaced six items, three of them about colour. This revision
supersedes the 2026-09-06 petrol revision above (kept for the record).

**The brand accent is now forest green** — `#1B5E3F` light / `#58BF95` dark,
pressed `#124A31` / `#3E9E78`. The owner used the petrol accent for a day and
preferred a deeper, less teal green. `#1B5E3F` clears AAA on white (7.7:1);
the dark value is a luminosity-raised forest tuned by eye. Same one code
change as last time for the tint itself: the `AccentColor` / `AccentPressed`
colorsets only, every call site already goes through `Palette.accent`.

**The app icon and launch mark are regenerated — and their generator is now
committed.** The 2026-08-25 icon revision made the PNGs with a CoreGraphics
script that was never checked in, which is why the indigo→petrol swap left
the home-screen icon indigo and the petrol→forest swap would have left it
petrol. `scripts/gen-app-icon.swift` (+ `make icon`) is that script,
committed this time: the hero-band gradient behind three ascending white
bars (echoing `BucketBarsChart`), the iOS 1024 opaque and alpha-free, the
macOS ten-slot set with the squircle baked in at Apple's ~9% inset, the
launch mark the accent bars alone on transparent. The next colour change is
one command.

**Accent is now close in hue to `income` / the `green` data tone.** They were
different colours before; they now stay apart only by a ~17° hue shift and a
lightness gap. The load-bearing pairing is a positive `net` (accent) beside
`Entrate` (income) in the dashboard hero — checked in the visual pass. If it
ever reads as one colour, `income` moves, not the accent.

**"Too white" — the accent had no presence on the first screen.**
`DashboardView` used `Palette.accent` zero times, and `Card`'s drop shadows
were double-multiplied (`Palette.cardShadow` carried `.opacity(0.16)`, then
the modifiers multiplied it again — the far shadow rendered at ~1/14 of the
value in `docs/design/tokens.md`), so cards had almost no elevation against
the background. Fixed together:

- `Palette.cardShadow` is now opaque `Color.black`; the `Card` modifiers
  carry the documented `.04` / `.22`.
- New tokens: `accentTint` (a pale brand wash for resting surfaces — active
  filter tokens, card eyebrows), and a `heroFill` / `heroFillDeep` /
  `onHero` / `onHeroSecondary` set for a filled band behind the dashboard
  hero figure. The hero band is its **own** colorset, deep forest in both
  appearances — the dark accent is a light mint and white text on it would
  fail contrast.
- `Background` shifts `#F5F5F7` → `#F2F5F3`, a barely-green neutral.
- The category ribbon and everything below the hero figure stay on card
  white — category tones (`slate`, `indigo`, …) on forest green are muddy
  and would break "colour comes from the data".

**A per-user accent picker stays parked** (`tasks/backlog.md`), same
reasoning as the petrol revision.

**Verified**: `make test-core` and `make test-app` unchanged (no logic
touched); `xcodebuild` clean, zero warnings. Manual pass still owed — every
screen light and dark, Dynamic Type up, accent-vs-income in the hero, and the
home-screen icon (regenerated in the same milestone).

## 2026-09-08 revision: a tone pass — harmonized data palette, filled tiles, elevations, figure treatment

After starting to use the app daily the owner said it still read as a
"vibe-coded app": the ten data tones were Apple's system colours at full
chroma with luminosity all over the place (`red` ~48, `amber` ~75), six of
them in a row in the donut and the category ribbon; one flat `Card` and one
shadow on every screen; the system type used at its defaults. The reliability
and accent work of the "Bella e affidabile" milestone had not touched any of
that.

Scoped as a **tone pass** — three system changes plus a recompose of the two
daily screens. Judged on a dedicated design canvas ("Traccio Visual Tone", a
separate artifact from the M3 canvas) before any SwiftUI, same as Fase B.
Client-only, no backend, no schema change.

**1 — The ten `PaletteColor` light values are rebuilt on one perceptual
model.** Same ten names, same hue families (a "blue" category still reads
blue), but luminosity is levelled across the tones and chroma is equalized —
raised back toward Apple's saturation so they are not timid, but consistent so
ten tones read as one family instead of ten unrelated system colours. The
contrast-vs-white spread goes from 2.6× to ~1.3×. Dark values are unchanged.
No data migration: a stored `PaletteColor` is a name, and every name still
resolves. e.g. green `#248A3D`→`#009F63`, blue `#2A78D6`→`#4687DB`, red
`#D70015`→`#CF5E55`.

**2 — `IconTile` anatomy flips to solid fill + white glyph.** The old tile was
a pale tint background with a thin coloured glyph; at 28–32pt row size a
2pt coloured stroke on near-white read as muddy no matter the value — this was
most of what "opaque" meant. The colour now fills the tile and the glyph is
white `.semibold`, which is where the saturation carries (the Revolut/Monzo
pattern). `Palette.tint(_:)` had exactly one consumer — this tile — so the ten
`PaletteColor<Name>Tint` colorsets and the accessor are deleted with it.

**3 — Three elevation levels replace the single card recipe.** `CardElevation`
`.flush` (border only) / `.resting` (one soft shadow, the new default) /
`.raised` (the deep two-layer, for what genuinely floats — `HeroCard`, a
sheet). One card and one shadow on every grouping was part of what read as
unfinished. In Movimenti this lands as a real grouping model: a day is now
**one** `.resting` card with hairline dividers between rows, not N rounded
rows floating 6pt apart each with its own shadow (the single most recognizable
tell). `TransactionRow` loses its per-row background/border/shadow; a muted
row gets a faint inset fill instead of the old dashed border.

**4 — `AmountText` gets a designed figure treatment.** The `",dd"` cents are a
separate run: a receded ink tone for a spend or a non-counted leg so the whole
units read first (income / positive net keep the tail coloured — a grey tail
on a green figure reads broken). A large protagonist figure — the dashboard
hero — also passes a smaller `fractionFont` and slight negative `tracking`.
Display-only; VoiceOver still reads the whole figure. Italian formatting only
(the split keys off a trailing "," + two digits and falls back to one run
otherwise).

Typography stays SF — no bundled face (this ADR's original review and Fase B
both rejected a display typeface as "generic AI product"). The "designed"
part is the figure treatment above plus tracking at figure sites, not a new
family.

**What is deliberately NOT in this revision.** The deeper Panoramica hierarchy
re-layout — quieter period picker, comparison demoted from a card to a
caption, a full `Spacing`/`Radius` sweep — is left for the on-device visual
pass rather than done blind. The `Conti` screen is untouched: the owner calls
it the cleanest, and it is the model the others follow.

**Verified**: `make test-app` 213 pass at each slice; `xcodebuild` clean. The
on-device visual pass — light + dark + Dynamic Type, every screen the palette
and surfaces touch — is owed, same as every prior visual revision here; no
unit test covers layout or colour.

## 2026-09-08 revision (second pass): deep-plum accent, Panoramica recomposed

The tone revision above shipped to the phone. On device two things stood out:
the forest-green accent still did not sit right — a green brand next to green
`income` (both green) reads as a semantic muddle, and it competed with the ten
data tones — and Panoramica had been left untouched (its hierarchy work was
deferred). Both addressed here; still client-only, no backend.

**Accent: forest green → deep plum.** `AccentColor` `#1B5E3F` / `#58BF95` →
**`#582832` / `#D48F96`**, `AccentPressed` → `#461823` / `#B6737B`,
`AccentTint` → `#FEECEE` / `#2F1D20`. `HeroFill` / `HeroFillDeep` move to a
deep plum to match the band (`#532730` / `#370D18` light). The owner chose a
warm-dark plum ("prugna / testa di moro") from a short set of non-green
directions. `#582832` is AAA on white (11.9:1); the dark accent is a
luminosity-raised warm rose. It is the fourth accent (indigo → petrol →
forest → plum) and the first that is deliberately not a green — the point is
to stop the brand colour from overlapping the `income` semantic and the data
palette. The one caveat: the dark accent is near the dark `pink` data tone in
luminance; they differ in hue and never share a surface (chrome vs. a
category glyph). `scripts/gen-app-icon.swift`'s palette constants are updated
and `make icon` re-run, so the home-screen icon follows this time.

**Panoramica recomposed for hierarchy.** The hero body was three stacked
sections (ribbon + legend, Entrate/Netto, and a three-column stat row) plus a
separate full `ComparisonCard` below — four things competing under one figure.
Now: the hero body is the ribbon + Entrate/Netto only; the three secondary
stats (media/giorno, movimenti, categorie) and the comparison collapse into
`heroFootnote`, a single `inkTertiary` caption line on the background under the
hero ("↓ 12% in meno di agosto · €175/g · 84 mov. · 12 cat."). The comparison
keeps `ComparisonCard`'s old two-colour rule (a rise in spend is `warning`, a
fall is `accent`) but reads as prose. `ComparisonCard.swift` is deleted. The
period strip drops the `accentTint` block for a quiet flush card — it is
navigation, not a headline. The donut, trend and per-account cards are
unchanged (they already carry the `.resting` elevation and their own
eyebrows).

**Still deferred**: the `Spacing`/`Radius` literal sweep of `DashboardView`
(tracked since ADR 0017), and the on-device pass of this whole revision —
light + dark + Dynamic Type — which is owed the same as every visual change
here.

**Verified**: `make test-app` 213 at each slice; `xcodebuild` clean.

### Accent, again: plum → cobalt blue (2026-09-08)

The deep-plum accent above lasted about half a day on device — the owner did
not warm to it ("chemmerda pure sto colore"). Fifth and (for now) final
accent: **cobalt blue `#025BAD` / `#6DABEC`**, `AccentPressed` `#01498E` /
`#528ECE`, `AccentTint` `#EAF3FE` / `#162434`, `HeroFill*` a deep blue to
match. `#025BAD` is 6.8:1 on white. It is deliberately deeper and more
saturated than the `blue` data tone (`#4687DB`) — a ~2:1 luminance step, so
"the brand blue" and "a blue category" do not read as the same colour — and
it is not the periwinkle/indigo that this ADR's first review and the indigo
data tone both rule out. `make icon` re-run so the home-screen icon follows.
The full accent lineage is now indigo → petrol → forest → plum → blue; the
lesson recorded here is that this choice is the owner's to make by eye on the
device, not one to litigate in advance.

Brightened once more the same day to `#056DB8` / `#66B2F2` (a PayPal-ish
premium blue, 5.4:1 on white) at the owner's request. In the same change,
Panoramica's period chevrons and card eyebrows drop the accent for `ink` —
the dashboard keeps blue off titles and navigation chrome; the comparison
delta stays `warning` for a rise in spend and `ink` otherwise.

Lightened again to a bright azure `#087ED7` / `#6FB4F3` (Apple `systemBlue`
territory, 4.2:1 on white) — the owner asked for it lighter twice. It is now
close to the `blue` data tone in lightness; the two stay apart by chroma
(the accent is much more saturated) and by never sharing a surface.

### Dose, not tint: the hero band goes, the accent gets a dosage rule (2026-09-08)

The azure above was the fifth accent in three days, and the owner still
disliked the "main colour" — "troppo imperante in alcune parti dell'app", the
dashboard's navy hero band called "un pugno in un occhio", the app icon "TROPPO
SCURA" next to every other app on the home screen. The pattern across all five
swaps: each hue was fine in isolation and grating in use within a day. The
conclusion recorded here is that the variable that kept failing was **surface
area, not hue** — the accent was the hero-band fill, the icon background, a
section title, every trend bar, a role pill, an avatar. Any colour spread that
wide becomes the colour you stare at all day.

**Decision.** Keep the azure. Cut the dose.

- **Panoramica's hero band is removed.** `HeroCard.swift`, the `HeroFill` /
  `HeroFillDeep` / `OnHero` / `OnHeroSecondary` colorsets, and `AmountText.Tone`
  are deleted. The hero is now a plain `Card` at `.raised` — the only raised
  card on the screen, so it stays the protagonist through elevation and the
  figure's scale (`Typography.heroFigure` → 44pt, tracking `-1.0`), not a block
  of colour. The iOS navigation title goes `.inline` so it does not compete
  with the figure. This matches `Conti`, which has always had no band and no
  accent surface and is the screen the owner calls the cleanest.
- **An "Accent dosage" rule** is added to `docs/design/tokens.md`: the accent
  marks what you touch or what is currently selected — a button, a link, an
  active filter chip, the active tab, a pressed state — and nothing else. Never
  a filled surface, a heading/eyebrow, or navigation chrome; at most one filled
  CTA per screen. Meaning comes from the data's own `PaletteColor` or from
  `Palette.income`, not from the accent.
- **Call sites bonified**: `AmountText.Kind.net` positive → `Palette.income`
  (was `accent`); `BucketBarsChart` bars → `Palette.ink.opacity(0.16)` at rest,
  `accent` only on the scrubbed bar; the "Per conto" eyebrow → `ink`; the
  transfer-suggestion card → a plain card, not an accent slab; `TransactionRow`
  role glyph, the advance split bar and participant avatars, the import "Nuovi"
  stat → neutral ink. `LockScreenView` / `PrivacyCoverView` keep a single
  accent glyph — a brand moment on an otherwise empty screen, not a surface.

**Rifinitura in the same pass** (each small, none load-bearing on its own):
skeleton placeholders (`Skeleton.swift`) replace the three bare
`ProgressView()`s on Panoramica / Movimenti / Conti; `PressableButtonStyle`
gives tappable rows and cards a scale + veil press state to go with the
haptics that were already there; `AmountText` carries
`.contentTransition(.numericText)` so figures roll rather than snap; the tab
bar switches to symbols with filled variants (`chart.bar`,
`list.bullet.rectangle.portrait`) so every tab lights when active; the dark
`Background` moves off pure black to `#0B0B0C`.

**App icon.** `scripts/gen-app-icon.swift` gains its own `iconTop` /
`iconBottom` / `launchBar` constants instead of aliasing the (now deleted)
`heroFill`. The navy `#024981 → #002C52` gradient was the darkest icon on the
home screen; the owner picked variant "C" from four rendered candidates — a
bright vertical wash `#22C7E8 → #0A84FF` (cyan to azure) with the same three
white bars. The launch mark keeps `launchBar` = `Palette.accent` `#087ED7`
(white bars would vanish on the app's own background).

**Verified**: `make test-app` 218, `make test-core` unaffected, `xcodebuild`
clean for macOS and iOS. The on-device pass — light + dark + Dynamic Type,
now including the band-less Panoramica and the raised dark background — is
owed the same as every visual change in this ADR.

## 2026-09-09 revision: Eventi and Anticipi recomposed to the shipped idiom

The Eventi and Anticipi screens (ADR 0026 / the 2026-08-24 Eventi slice) were
built before the "dose, non tinta" tone work and never revisited — a
`ProgressView` on first load, `EventRow` with no leading tile, N rounded rows
each with its own divider inside one flat `Card`. This revision brings both to
the idiom the tone revision established for Movimenti, alongside the Eventi
feature work in ADR 0027 / ADR 0028.

- **`EventsView`**: `ListSkeleton` replaces the spinner; events render as one
  `.resting` `Card(contentPadding: 0)` per section (active, then a separate
  "Chiusi" section) with hairline dividers between self-padded rows and
  `.pressableRow`; the "Nuovo evento" CTA is its own element below, not a row
  inside the list card. `EventRow` leads with an `EventTile` (ADR 0027).
- **`EventDetailView`**: the header is now the screen's **one** `.raised`
  card — `EventTile` + name + status badge, the net total at
  `Typography.heroFigure`, and a single `inkTertiary` footnote line
  ("N movimenti · 3–17 mag · 4 categorie"), the same treatment "dose, non
  tinta" gave Panoramica. `EventSections`' old plain "totale netto" card is
  removed (it duplicated the header). Below: the category breakdown card
  (ADR 0028, reusing `DonutChart` / `CategoryBreakdownList` unchanged), the
  members list, the "Movimenti suggeriti" card (ADR 0028), then the actions.
- **`AdvancesView`**: `ListSkeleton` replaces the spinner; the advance rows
  and the now-navigable "Chi ti deve" rows (ADR 0026 follow-up) take
  `.pressableRow`. The three summary cards keep their structure — they are
  one `Card` per grouping already, not the "N floating rows" tell.

No token changed. The accent-dosage rule is respected throughout: no accent on
the Eventi/Anticipi headings or chrome, the event's identity colour is the
data's own `PaletteColor` (an `EventTile`, not the brand accent), and each
screen has at most one filled CTA.

**Canvas**: `docs/design/canvas/` still has no Eventi or Anticipi artboard —
tracked in `tasks/backlog.md`. As with every screen since Fase C, these were
built from `docs/design/tokens.md` directly and are owed the on-device
light/dark/Dynamic-Type pass, not a mockup.

**Verified**: `make test-core` 402, `make test-app` 230, `xcodebuild` clean
for macOS and the iOS Simulator, `make lint` clean.

## 2026-09-15 revision: Liquid Glass in the chrome

Full decision in `0030-liquid-glass-chrome.md`. Deployment target raised to
iOS 26 / macOS 26 (both target devices already exceed it), and Liquid Glass
adopted in the chrome layer only — tab bar, toolbars, sheet action bars,
`PillButton`, `IconButton`, `FilterChip`, the new `SelectionSheet`. `Card`
and every figure-bearing surface stay exactly as the 2026-09-08 revision left
them: this is the same "dose, non tinta" discipline restated for material
instead of hue. `docs/design/tokens.md` gains a **Glass** section recording
which components carry it.

## 2026-09-15 revision: visual coherence pass

Full decision in `0031-visual-coherence-pass.md`. The Liquid Glass revision
above had only touched Movimenti's own toolbar and filter sheet; this
revision applies the same chrome — glass rule unchanged, only its reach —
to every screen and sheet: a shared `screenChrome`/`sheetChrome` modifier
pair, detents and a drag indicator on all 17 sheets, a large collapsing
title on the four tabs (Panoramica included, reversing its `.inline` call
from the 2026-09-08 revision — owed on-device judgment), and a single
`DisclosureChevron` in place of one that had drifted to four sizes and two
colours across seven files.
