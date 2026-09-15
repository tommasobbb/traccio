# 0033 — "Altro" tab and Impostazioni in Panoramica's corner

Status: accepted

Date: 2026-09-16

## Context

ADR 0009 added a fourth "Impostazioni" tab as the container for every
settings-shaped screen the client has or will have, and it landed there
first because the tab was framed as one thing: a settings destination.
Since then, three entries accumulated inside it — "Categorie e regole",
"Eventi", "Anticipi" — and none of them is actually a setting. A category
rule, an event, an advance are things the user *does*: they carry their own
data, their own write flow, their own place in `DataFreshness`. "Inizio
tracciamento", "Buoni pasto", biometric lock, and the server connection are
the opposite: things the user *configures* once and rarely revisits. The
tab had quietly become two different screens sharing one dock slot, and the
owner named the mismatch directly: settings don't deserve dock real estate
at all, while Eventi/Anticipi/Categorie e regole are used often enough that
burying them one tap behind a settings-labeled icon undersells them.

ADR 0009 itself considered and rejected "a gear icon on Panoramica," but for
a narrower reason than this decision revisits: `DashboardView` had no
toolbar at all at the time, and a gear hanging off one tab's corner for what
was then a single-purpose settings screen felt like inventing a hierarchy
that didn't exist. Two things have changed since: Panoramica still has no
other toolbar item to compete with, and "Impostazioni" is no longer a
single-purpose screen fighting for dock space — it is exactly the
corner-icon-shaped set of screens ADR 0009 was worried didn't exist yet.

## Decision

**The fourth tab stops being "Impostazioni" and becomes "Altro"**, holding
every feature screen that isn't one of the three daily-use tabs: Eventi,
Anticipi, Categorie e regole (`App/Sources/More/MoreView.swift`, built from
the same `Card`/`NavigationLink` row idiom `SettingsView` used, so no new
visual language). Icon `ellipsis.circle` — the same "more/other" reading
Apple's own apps use for an overflow tab, not a grid-of-features metaphor
that would overstate how much lives here.

**Impostazioni leaves the dock** and becomes a toolbar button in the
top-right corner of Panoramica (`gearshape`, pushed into Panoramica's own
`NavigationStack` — not a sheet, matching how every other settings-shaped
screen in this app is a push, not a modal). It now holds only "Inizio
tracciamento", "Buoni pasto", biometric lock (iOS), and the server card.

**What does not change:** the three daily-use tabs (Panoramica, Movimenti,
Conti) keep their exact shape and order; `DataFreshness`'s invalidation
calls (`CategorizationView`'s `onSuggestionsChanged`, `TrackingStartView`'s
`onChanged`) move with the screens that own them and are otherwise
untouched; `AppLock`/`DataFreshness`/`TransactionsDrillThrough` stay
injected once on the `TabView` in `TraccioApp.swift`, so both `MoreView` and
the pushed `SettingsView` see them without any new wiring.

## Consequences

- `SettingsView` and `MoreView` are each smaller and more honest about what
  they hold than the old combined "Impostazioni" was.
- Panoramica gets its first toolbar item. ADR 0009's stated reason for
  rejecting a gear icon there (no toolbar existed, and the screen behind it
  wasn't corner-icon-shaped yet) no longer holds, on both counts.
- `EventsView`/`AdvancesView`/`CategorizationView`'s doc comments ("Reached
  from the Impostazioni tab") are updated to name "Altro" instead; their
  actual code is untouched — they're still pushed screens with no
  `NavigationStack` of their own, same as before.
- ADR 0009 is annotated with a pointer to this ADR rather than rewritten —
  its own analysis (why a fourth tab needed to exist at all) is still
  correct; only what the tab now contains has changed.

## Alternatives considered

- **Keep four tabs, rename "Impostazioni" to something broader that covers
  both settings and features.** Rejected: a single label can't honestly
  describe both "things you configure" and "things you do" — the mismatch
  that motivated this ADR would just move into the tab's name instead of
  being resolved.
- **Drop to three tabs, put Eventi/Anticipi/Categorie e regole behind the
  same settings-corner icon as the real settings.** Rejected: these three
  are used often enough in daily life (checking who owes what, logging a
  trip's spending) that burying them one tap behind a *settings* icon
  undersells them exactly the way the old combined tab did — the dock slot
  is worth keeping for them, just not labeled "Impostazioni" anymore.
- **A sheet instead of a push for Impostazioni.** Rejected: every other
  settings-shaped screen in this app (Eventi, Anticipi, Categorie e regole,
  Inizio tracciamento) is a `NavigationLink` push; a sheet here would be the
  one settings destination presented differently for no reason tied to its
  content.

## Revisit when

- A fifth feature screen needs a home — confirms "Altro" is the right shape
  rather than a temporary two-tab compromise.
- The on-device pass (`tasks/backlog.md` item 13) finds the toolbar gear
  competing with the large collapsing title on Panoramica for attention —
  the fix is a smaller/quieter icon treatment, not moving it off Panoramica
  again.
