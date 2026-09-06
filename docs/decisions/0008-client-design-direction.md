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
