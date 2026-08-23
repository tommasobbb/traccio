# Design tokens

The settled values behind the client's light UI (`docs/decisions/0008-client-design-direction.md`).
This file is the one to read before writing SwiftUI — it gives you the exact
values and their Swift names. `docs/design/canvas/` holds the mockup sources if
you need to *look* at a screen instead; the published canvas artifact (linked
from ADR 0008) is the same thing rendered.

Direction: light and airy, Apple-native — system font, a distinctive but
restrained accent, semantic color used sparingly. Not a literal recreation of
any shipping app.

## Surfaces

| Token           | Hex       | Swift name              | Use                          |
| ---------------- | --------- | ------------------------ | ----------------------------- |
| Background       | `#F5F5F7` | `Palette.background`     | Screen background              |
| Card              | `#FFFFFF` | `Palette.card`           | Card fill                      |
| Neutral fill      | `#E5E5EA` | `Palette.neutralFill`    | Icon tiles, dividers, tracks   |

## Ink (text)

| Token       | Hex       | Swift name          | Use                                  |
| ----------- | --------- | -------------------- | -------------------------------------- |
| Primary     | `#1C1C1E` | `Palette.ink`        | Headlines, primary amounts             |
| Secondary   | `#6E6E73` | `Palette.inkSecondary`| Labels, captions                      |
| Tertiary    | `#8E8E93` | `Palette.inkTertiary` | Muted metadata (dates, counts)         |
| Quaternary  | `#AEAEB2` | `Palette.inkQuaternary`| Non-counted amounts (transfers, etc.) |

## Accent

| Token          | Hex       | Swift name           | Use                                |
| -------------- | --------- | ---------------------- | ------------------------------------ |
| Accent         | `#5856D6` | `Palette.accent`       | Brand indigo — links, positive net, active tab |
| Accent pressed | `#423FC0` | `Palette.accentPressed`| Pressed/hover state                  |

## Semantic

**Spending stays in ink, never red.** This is the rule most likely to get
violated by accident — a spend row uses `Palette.ink`, not a red. Red is
reserved for category iconography only (e.g. a restaurant icon tile), never for
an amount.

| Token         | Hex       | Swift name              | Use                                   |
| ------------- | --------- | ------------------------ | ---------------------------------------- |
| Income        | `#248A3D` | `Palette.income`         | Positive amounts (salary, reimbursement) |
| Income tint   | `#E2F7E6` | `Palette.incomeTint`     | Income icon tile background              |
| Warning       | `#C2660A` | `Palette.warning`        | Consent-expiry banner text/icon          |
| Warning tint  | `#FFF1DE` | `Palette.warningTint`    | Consent-expiry banner background         |
| Warning border| `#FFD8A8` | `Palette.warningBorder`  | Consent-expiry banner border             |
| Status dot    | `#FF9500` | `Palette.statusWarn`     | Connection status dot (expiring soon)    |
| Category red  | `#D70015` | `Palette.categoryRed`    | Category icon only — never an amount     |
| Category red tint | `#FFEDEC` | `Palette.categoryRedTint`| Category icon tile background        |

`net` in the dashboard hero carries `Palette.accent` when positive (the only
place accent doubles as a semantic color, because `net` is the one genuinely
signed figure — see ADR 0007).

## Separators and shadows

| Token             | Value                              | Use                        |
| ------------------ | ----------------------------------- | ---------------------------- |
| Separator (subtle) | `rgba(60,60,67,.06)`                | Card border                  |
| Separator (visible)| `rgba(60,60,67,.08)`–`.12`          | Dividers, stat separators    |
| Card shadow, near   | `0 1px 2px rgba(0,0,0,.04)`         | Card elevation, layer 1      |
| Card shadow, far    | `0 14px 28px -18px rgba(0,0,0,.22)` | Card elevation, layer 2      |

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
palette (blue/orange/pink/gray used in the "Concept" donut) was left
unchanged — it is a functional categorical palette, not part of the app's
tone, and is not relevant until the category-breakdown backend item exists.
