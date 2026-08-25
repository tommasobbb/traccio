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

## Category chart

The dashboard's "Per categoria" donut and legend (`docs/design/canvas/Main.dc.html`,
unblocked once `GET /dashboard/summary` started returning `by_category` —
`docs/decisions/0007-dashboard-aggregation.md`'s "Revisit when"). A rank-based
palette, not a per-category one: color is assigned by position in the sorted
list (biggest spender first), so a category's color can shift between months
if its rank does. A real per-category color is a separate, deliberately
deferred decision (`tasks/backlog.md`).

| Token           | Hex (light) | Hex (dark) | Swift name                  | Use                              |
| ---------------- | --------- | --------- | ----------------------------- | ----------------------------------- |
| Category chart 1 | `#2A78D6` | `#409CFF` | `Palette.categoryChart1`      | Rank 1 (biggest spender) — blue    |
| Category chart 2 | `#EDA100` | `#FFC53D` | `Palette.categoryChart2`      | Rank 2 — amber                     |
| Category chart 3 | `#EB6834` | `#FF8F66` | `Palette.categoryChart3`      | Rank 3 — orange                    |
| Category chart 4 | `#E87BA4` | `#FF9EC0` | `Palette.categoryChart4`      | Rank 4 — pink                      |
| Category chart 5 | `#1C93A6` | `#4DC8DB` | `Palette.categoryChart5`      | Rank 5 — teal (new; a fifth rank color the canvas never needed) |
| Category chart, no category | `#8E8E93` | `#6C6C70` | `Palette.inkTertiary`  | Fixed — the "Senza categoria" bucket never rotates through ranks |
| Category chart track | `#E5E5EA` | `#2C2C2E` | `Palette.neutralFill`  | Donut background ring |

Dark values are each light value raised in luminosity, same relationship as
the ink and accent adjustments above: a chart segment this saturated at the
light hex would read muddy against the near-black dark background.

Green is deliberately excluded from the rotation — it is reserved for
`income`, and a green donut segment next to a green income figure would read
as two different things. Ranks beyond 5 (a sixth-or-later category, or the
"no category" bucket when it isn't the smallest) reuse `categoryChart5` rather
than growing the palette further; that ambiguity is judged better than adding
a sixth rank color for a case the four-way canvas mockup never had to solve.

Two corrections from the canvas's first-cut values, made here because ADR 0008
already rejected the same warm, off-palette instinct once (see History
below): the canvas's donut track was `#EFEEE9` (a warm off-white) — replaced
with `Palette.neutralFill`, the cool gray already used for every other track
and fill; and the canvas's fifth/grey slice `#C7C6CE` — replaced with
`Palette.inkTertiary`, already the palette's own cool gray rather than an
unrelated one introduced just for this chart.

## Daily bars

The dashboard's "Spesa giornaliera" bar chart (`docs/design/canvas/Main.dc.html`,
badge removed once `by_day` shipped —
`docs/decisions/0007-dashboard-aggregation.md`'s 2026-08-25 revision). No new
tokens: the fill reuses `Palette.accent` (the same color as the donut's rank-1
segment coincidentally, but not linked — this chart has one series, not a
rotation) and the track reuses `Palette.neutralFill`, same as the donut's own
track.

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

| Element        | Radius |
| -------------- | ------ |
| Card           | 20     |
| Row            | 16     |
| Icon tile      | 12     |
| Pill / chip    | 999 (fully rounded) |

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

| Token              | Value |
| ------------------- | ----- |
| Screen gutter        | 20    |
| Gap between cards    | 14–16 |
| Card internal padding| 18–20 |

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
item shipped: see the "Category chart" section above for the final five
colors (a teal added for a fifth rank) and the two corrections made to the
canvas's warm off-palette track and grey.

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
