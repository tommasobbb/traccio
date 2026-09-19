# 0038 — Anticipi's list screen inherits its own detail screen's treatment

Status: accepted
Date: 2026-09-19

## Context

`AdvancesView` ("Anticipi") was three cards of caption-scale text: a totals
line, a "chi ti deve" list with no leading element, and an advances list with
no leading element either — the only lists in the app without one. The
paradox: `PersonDetailView`, reached by tapping a row in the second card, is
*richer* than the screen it's reached from — a `.raised` hero figure, a
`ProgressBar`, and an Atteso/Rientrato figure pair. A user opening the tab
sees the flattest screen in the app, then one tap later sees the one that
actually explains the number.

`PersonSummaryResponse` already carries `expected`/`reimbursed` (ADR 0026);
`ReceivableTotal`, the cross-currency total behind the totals card, didn't —
`total_receivable` only ever summed `outstanding` and a per-status count. The
client never sums figures itself (`docs/engineering.md`), so the totals
card's own progress bar needed the same two fields at the aggregate level
before it could be built at all.

## Decision

1. **The list screen copies its own detail screen's anatomy rather than
   inventing a second one.** `AdvancesView`'s totals card becomes the
   screen's one `.raised` protagonist (matching `PersonDetailView.summaryCard`
   and the dashboard hero — "one `.raised` card is the protagonist" is now a
   three-screen pattern, not one): headline figure, `ProgressBar`, an
   Atteso/Rientrato pair via a new shared `advanceFigureColumn` helper. "Chi
   ti deve" rows and advance rows both gain a leading `InitialsAvatar` (a
   participant's initials, or a neutral `person.2.fill` disc for zero/several
   participants) — promoted from a private helper `AdvanceSections` already
   had, since two more call sites needed exactly the same thing. A person row
   also gains a narrow inline `ProgressBar` next to its advance count.
2. **`ReceivableTotal` (backend) gains `expected`/`reimbursed`**, accumulated
   with the *same written-off exclusion* `outstanding` already used — a
   written-off advance's receivable and reimbursed amounts stay populated on
   its own `AdvanceState` but contribute 0 to every one of the three totals,
   for the same reason: the user stopped expecting that money. `expected -
   reimbursed` can diverge from `outstanding` on an over-reimbursed advance
   (`outstanding` clamps at zero; the other two don't), exactly the
   `PersonSummary` posture this mirrors.
3. **The fraction computation is shared, not duplicated a third time.**
   `PersonDetailView` had a private `fraction(_:)`; `AdvancesView` needed the
   same shape for both the totals card and the person rows. Both now read
   `person.reimbursedFraction` / `total.reimbursedFraction` from one
   presentation-only file (`ReimbursedFraction.swift`, in the feature folder,
   not `TraccioCore` — the same "display copy stays in the view" posture
   `CalendarPeriod+DisplayTitle.swift` already set: the client divides two
   numbers the server gave it, it doesn't derive anything new).
4. **The empty card gets a pointer to the actual gesture, not a button.**
   Every other empty card in the app that can act ends in a `PillButton`
   (`EventsView`); Anticipi's can't, because an advance has no standalone
   creation flow — it only ever starts from a transaction row's own "Segna
   come anticipo" action. The empty state now names that path in bold instead
   of silently having no way forward, which is exactly what it looked like
   before (only the explanatory sentence, no next step at all).

## Consequences

- `ReceivableTotalResponse` (wire schema) gains `expected`/`reimbursed` (int,
  cents) — an additive field, no breaking change for any other consumer.
  `client/Packages/TraccioCore`'s Swift model gains the matching fields; every
  fixture and test constructing one needed updating (there is no default
  value — the two are as load-bearing as `outstanding`).
  `docs/api/openapi.json` regenerated (`make openapi`).
- No migration, no other backend behavior change — `total_receivable` is a
  pure derivation over already-loaded `AdvanceState`s, same as before.
- `AdvanceSections.swift` loses its private `avatar(for:)`/`initials(for:)` in
  favor of the shared `InitialsAvatar` — its two-letter initials ("Marco
  Rossi" → "MR") is a small visible change there too, not just on the two new
  call sites, since a one-letter avatar read as anonymous for the common case
  of a full name.
- Still no mockup for this screen (`docs/design/canvas/` has no Anticipi
  artboard, `tasks/backlog.md`'s "Deferred from the Eventi/Anticipi batch"
  item) — built from tokens/existing components, same posture as before.

## Alternatives considered

- **A segmented Persone/Anticipi control instead of two stacked lists.**
  Rejected for this batch: it changes the screen's navigation shape, not just
  its anatomy, and the request was to fix illegibility, not restructure the
  information architecture. Left as a future option if the two stacked lists
  ever feel redundant on device.
- **Client-side summing of `expected`/`reimbursed` from the visible rows**,
  avoiding a backend change. Rejected on the same grounds ADR 0026 already
  established for `outstanding`: the client renders, it doesn't derive
  cross-row totals — `tracking_start_date` filtering and per-currency
  written-off exclusion are exactly the kind of business rule that belongs in
  one place, not re-implemented at the edge.

## Revisit when

- The on-device visual pass (`tasks/backlog.md` item 13, `docs/design/tokens.md`'s
  standing item) reaches this screen — it's new territory, not a revision of
  something already judged on a device.
- A canvas artboard is ever added for Eventi/Anticipi (still deferred) — it
  should capture this anatomy rather than the flat-text one it would have
  captured before this ADR.
