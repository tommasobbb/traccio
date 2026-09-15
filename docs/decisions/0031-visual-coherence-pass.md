# 0031 — Visual coherence pass: chrome, sheets, motion applied everywhere

Status: accepted
Date: 2026-09-15

## Context

The owner reported the app doesn't feel visually coherent: some parts read
as very "Liquid Glass," others completely different. The diagnosis was not
"stock vs custom" — `App/Sources` has zero `Form`/`List`/`GroupBox`, every
screen is already `ScreenBackground` + `Card` + `Palette`, per ADR 0008. The
real gap was that the Liquid Glass batch (ADR 0030, merged the same day)
touched **8 call sites in 5 files**, concentrated on Movimenti: the filter
sheet got detents, a glass selection bar, and `GlassEffectContainer`-blended
chips, while Panoramica — the landing screen — got no glass at all and kept
a stock `.segmented` `Picker` at the top. 14 of 16 sheets had no detents, no
drag indicator, and hand-rolled `TextField`/`DatePicker` styling. The four
tabs' nav-title display modes disagreed (Panoramica alone `.inline`, the
other three left at `.automatic`). A `Spacing`/`Radius` sweep tracked since
ADR 0017 (`tasks/backlog.md` item 14) was still open in 28 of 34 files, and a
disclosure chevron rendered at four different sizes and two different
colours across seven files — a second, smaller instance of the same
"different corners of the app look different" complaint.

## Decision

**1. ADR 0030's rule is unchanged, only its reach.** Glass stays chrome,
never a content surface — `Card` and anything carrying a figure are
untouched by this pass. What changes is that the rule is now applied
identically everywhere, not just on Movimenti.

**2. Three new shared modifiers own screen/sheet chrome**
(`App/Sources/DesignSystem/`):

- `View.screenChrome(_:style:)` (`ScreenChrome.swift`) — background gradient,
  nav title, and `.scrollEdgeEffectStyle(.soft, for: .all)`. `style: .tabRoot`
  (Panoramica, Movimenti, Conti, Impostazioni) gets a large title that
  collapses on scroll, matching every stock Apple top-level list. `style:
  .pushed` (the default — Eventi, Anticipi, Categorie e regole, Inizio
  tracciamento, every detail screen) stays inline throughout, same as a
  stock app's own drill-down (Impostazioni ▸ Wi-Fi is never `.large`) —
  this is deliberately **not** "large everywhere": forcing a large title on
  a pushed detail screen would break the convention `PersonDetailView`
  already followed and fight the content for protagonist billing.
- `View.sheetChrome(_:detents:)` (`SheetChrome.swift`) — background,
  inline title, `.medium`/`.large` detents, and a visible drag indicator,
  now on all 17 sheets (2 had this by hand before; 15 had none).
- `View.rowScrollTransition()` (`RowMotion.swift`) — the quiet
  opacity+scale entrance now shared by `TransactionRow`, `EventRow`,
  `RuleRow`, `BreakdownRowView`, and `AdvanceSections`' participant/
  reimbursement rows.

**3. Panoramica moves to `.tabRoot`.** This revises the 2026-09-08 "dose,
non tinta" call to keep it `.inline` so the hero figure alone carried the
top of the screen. On-device judgment is still owed (`tasks/backlog.md`
item 13): if the large title fights the hero figure for protagonist, this
reverts to `.pushed` and every tab follows, rather than leaving Panoramica
the odd one out again.

**4. `DisclosureChevron`** (`DesignSystem/DisclosureChevron.swift`)
replaces seven ad hoc `Image(systemName: "chevron.right")` call sites that
had drifted to four sizes (11/12/13pt, plus `.caption`'s regular weight) and
two colours (`inkQuaternary` in five places, `inkTertiary` in two). One
11pt/`.semibold`/`inkQuaternary` glyph, matching the majority.

**5. Four picker-shaped sheets adopt `OptionListCard`/`OptionRow`**
(`EventPickerSheet`, `CreateRuleSheet`'s category list,
`AddReimbursementSheet`'s participant list) in place of hand-rolled `Card` +
`Divider` rows — the same component ADR 0030 §4 already established for
`TransactionFiltersSheet`/`SelectionSheet`. `OptionRowLayout` was factored
out of `OptionRow` so `EventPickerSheet` can plug an `EventTile` (ADR 0027's
emoji wash) as the leading glyph instead of `OptionRow`'s `IconTile`/swatch
pair, which can't express it.

**6. Two new components close real duplication**: `LabeledField`
(`EyebrowLabel` + `TextField`/`SecureField`, ~10 call sites that hand-rolled
the same font/colour/autocorrection triple) and `.segmentedPickerTint()`
(6 of 7 segmented pickers were untinted). `TrackingStartView`'s
`primaryButton`/`secondaryButton` — the one accent CTA pair still painted
with a flat fill — move to `.glassProminent`/`.glass`, the same idiom as the
Filtri sheet's "Applica" bar (not `PillButton`: that component is a compact
capsule, wrong shape for a full-width settings action).

**7. `Spacing`/`Radius` sweep, closing ADR 0017/item 14's debt where a token
actually fits**: 27 `.padding(20)` → `Spacing.gutter`, 24
`VStack(spacing: 16)` stacks-of-cards → `Spacing.cardGap`. Values with no
matching token (`Card`'s own `contentPadding` overrides, a colour swatch's
3pt corner, the FX tile's `cornerRadius: 14` already flagged in
`tasks/backlog.md`) are left as literals rather than forced into the wrong
token or given a one-off token of their own (YAGNI, `.claude/rules/swift.md`)
— not every literal is missing coverage; some are legitimately unique.

**8. Small motion additions**: a symbol morph
(`.contentTransition(.symbolEffect(.replace))`) when Movimenti's filter
glyph switches between its filled/outline state instead of snapping, and a
`.symbolEffect(.pulse)` on the lock screen's Face ID/Touch ID glyph while
`AppLock.state == .authenticating` — the same ambient cue the system's own
biometric prompt gives. A `GlassEffectContainer` around Anticipi's one status
`FilterChip` was considered and dropped: it wraps a single glass element, so
it would be inert, the same lesson `docs/design/tokens.md` already recorded
for a `GlassEffectContainer` around Movimenti's toolbar.

## Consequences

- `docs/design/tokens.md` gains "Screen chrome" and "Sheet chrome" sections
  and an updated Glass table entry for `DisclosureChevron`.
- `tasks/backlog.md` item 14 (the `Spacing`/`Radius` sweep) closes for every
  literal that had a real token to move to.
- No change to the accent, the ten `PaletteColor` tones, typography sizes,
  or elevation model — additive to chrome, sheets, and small-glyph
  consistency only.
- The on-device visual pass owed since 2026-09-07 (`tasks/backlog.md` item
  13) now also covers this batch's own additions: the large title on the
  four tabs, `scrollEdgeEffectStyle` in both appearances, detents/drag
  indicators on all 17 sheets, the `DisclosureChevron` size/colour against
  real rows, and the Face ID pulse.

## Revisit when

- The on-device pass finds the Panoramica large title fights the hero
  figure — revert every tab to `.pushed` and record it here rather than
  letting Panoramica drift again.
