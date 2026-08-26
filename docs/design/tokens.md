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
| Background       | `#F5F5F7` | `#000000` | `Palette.background`     | Screen background              |
| Card              | `#FFFFFF` | `#1C1C1E` | `Palette.card`           | Card fill                      |
| Neutral fill      | `#E5E5EA` | `#2C2C2E` | `Palette.neutralFill`    | Icon tiles, dividers, tracks   |

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
| Accent         | `#5856D6` | `#7D7AFF` | `Palette.accent`       | Brand indigo — links, positive net, active tab |
| Accent pressed | `#423FC0` | `#605DE0` | `Palette.accentPressed`| Pressed/hover state                  |

Dark accent is Apple's own `systemIndigo` dark value — lighter than the light
variant (the usual dark-mode adjustment so a saturated color stays legible on
a near-black background), not a re-derivation of the light hex.

The underlying asset is named `AccentColor`, not `Accent`: it doubles as the
target's global accent color (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`
in `client/Project.yml`, the tint system controls pick up automatically), so
`Palette.accent` reads that one asset rather than keeping a second colorset
in sync by hand.

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

## Daily bars

The dashboard's "Spesa giornaliera" bar chart (`docs/design/canvas/Main.dc.html`,
badge removed once `by_day` shipped —
`docs/decisions/0007-dashboard-aggregation.md`'s 2026-08-25 revision; renamed
`by_bucket` in the third revision). No new tokens: the fill reuses
`Palette.accent` and the track reuses `Palette.neutralFill`, same as the
donut's own track.

## Appearance tokens

The account and category colour/icon picker (ADR 0017, extended to categories
by ADR 0018). **User-chosen and persisted per entity**, not assigned by rank
or sorted position — a `PaletteColor` survives regardless of how a list
re-sorts, which is exactly why the dashboard donut/breakdown list above draws
from this same vocabulary rather than its own rank-based one. Each of the ten
tones ships as
two colorsets: a solid (`PaletteColor<Name>`, the icon glyph) and a paler tint
(`PaletteColor<Name>Tint`, the icon tile's background) — see `IconTile.swift`.

| Token   | Hex (light) | Hex (dark) | Swift name (`Palette.color(_:)`) | Wire value |
| ------- | --------- | --------- | ----------------------------------- | ---------- |
| Blue    | `#2A78D6` | `#409CFF` | `.color(.blue)`   | `blue`   |
| Indigo  | `#5856D6` | `#7D7AFF` | `.color(.indigo)` | `indigo` |
| Purple  | `#AF52DE` | `#BF5AF2` | `.color(.purple)` | `purple` |
| Pink    | `#E87BA4` | `#FF9EC0` | `.color(.pink)`   | `pink`   |
| Red     | `#D70015` | `#FF453A` | `.color(.red)`    | `red`    |
| Orange  | `#EB6834` | `#FF8F66` | `.color(.orange)` | `orange` |
| Amber   | `#EDA100` | `#FFC53D` | `.color(.amber)`  | `amber`  |
| Green   | `#248A3D` | `#30D158` | `.color(.green)`  | `green`  |
| Teal    | `#1C93A6` | `#4DC8DB` | `.color(.teal)`   | `teal`   |
| Slate   | `#8E8E93` | `#6C6C70` | `.color(.slate)`  | `slate`  |

`.tint(_:)` mirrors the same ten cases, each colorset's paler counterpart
(light: base blended ~12% toward white; dark: base blended ~24% toward
black — a systematic default, not the fully hand-tuned pass the rest of this
file follows; refining one by eye later is a fair follow-up). `slate` is the
neutral default for anything the user has not deliberately coloured yet.

Icons are a fixed SF Symbol map per entity, kept in `App/Sources/DesignSystem/
IconTile.swift` (`AccountIcon.systemImageName`) rather than on the wire enum —
the backend has no notion that SF Symbols exist (ADR 0017).

## Separators and shadows

| Token             | Value                              | Use                        |
| ------------------ | ----------------------------------- | ---------------------------- |
| Separator (subtle) | `rgba(60,60,67,.06)`                | Card border                  |
| Separator (visible)| `rgba(60,60,67,.08)`–`.12`          | Dividers, stat separators    |
| Card shadow, near   | `0 1px 2px rgba(0,0,0,.04)`         | Card elevation, layer 1      |
| Card shadow, far    | `0 14px 28px -18px rgba(0,0,0,.22)` | Card elevation, layer 2      |

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
