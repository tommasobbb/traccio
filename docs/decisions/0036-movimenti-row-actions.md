# 0036 — Row actions on Movimenti; the Dettaglio narrows

Status: accepted
Date: 2026-09-19

## Context

Every action on a Movimenti row went through the same door: tap the row,
push to `TransactionDetailView`, act there, back out. For categorization —
by far the most frequent action — that cost tap → wait for the push → scroll
past the header and event card → tap the category → back. The owner's
constraint, set while scoping this in an earlier conversation: categorizing
should take **at most two taps in total**. The toolbar also carried a `Menu`
("•••") whose only entry was "Collega trasferimento" — a service menu
dressed as a primary action, a peer of "Filtri" and "+" for a single rare
flow.

**The real constraint**, found while scoping this: `TransactionDetailView` is
*also* the advance detail screen. `AdvancesView` and `PersonDetailView` push
it (via `TransactionDetailLoader`) for every row, and it is where an
advance's split/participants/reimbursements/write-off/reopen live
(`AdvanceSections`). Deleting the screen outright would break the Anticipi
tab. It stays — but stops being the entry point for every action a row can
take.

## Decision

**Three gestures share a Movimenti row now:**

| Gesture | Effect |
| --- | --- |
| Tap the leading category tile | Opens `CategoryPickerSheet` — confirm, clear, or seed defaults. Two taps total. |
| Tap the rest of the row | Pushes to `TransactionDetailView`, unchanged as a gesture. |
| Long-press the row | Opens `.contextMenu`: Categorizza · Segna come anticipo · Collega a… · Modifica · Elimina. |

The context menu shows only entries that apply to the row —
`TraccioCore.canBecomeAdvance(_:)` for "Segna come anticipo",
`TraccioCore.canStartTransferLink(_:)` for "Collega a…" (a predicate lifted
out of `TransactionsView.rowSelection(for:)`'s hand-written rule, now tested
in `TraccioCoreTests`), and "Modifica"/"Elimina" only on a manual account
(ADR 0020) — never a disabled row.

**The leading tile's tap target** is an invisible 44×44 `Button` laid over
the tile as an `.overlay`, sibling to the `NavigationLink` rather than
nested in its label — a `Button` inside a `NavigationLink`'s label would have
its tap swallowed by the link. An uncategorized row's tile changed from a
solid grey fill (indistinguishable from an actually-categorized "other")
to a dashed outline with a tag glyph, so it reads as tappable and the list
is scannable for what still needs attention. No accent color on it — a data
state, not a selection (`docs/design/tokens.md`'s "Accent dosage").

**"Collega trasferimento" leaves the toolbar** and becomes "Collega a…" in
the row's own menu, which enters transfer-pairing selection mode with that
row already picked (`TransactionsViewModel.enterSelection(anchor:)`) — today
selection starts from zero and both rows must be chosen; the existing
guidance copy in `TransactionSelectionBar` already reads correctly with one
row pre-selected. The toolbar's `Menu` — its one entry — is gone; only
"Filtri" and "+" remain.

**The long-press context menu is a new idiom for this client.** Before this
change, no view used `.contextMenu`, `.swipeActions`, or
`onLongPressGesture` anywhere in `client/App/`. The closest existing analog
was the "•••" `Menu` button on `RuleRow.swift`. This is registered here
rather than assumed safe, and judged on-device rather than in review — see
Consequences.

**The writes that moved off the pushed screen** — category confirm/clear/
seed/create-rule (already row-level, `TransactionsViewModel+Category.swift`)
and mark-as-advance/edit-manual/delete-manual
(`TransactionsViewModel+RowActions.swift`) — all go through
`TransactionsViewModel`'s shared `isUpdatingRow`/`rowActionFailure` guard
(`beginRowAction()`/`endRowAction(failure:)`/`markRowActionSucceeded()`,
mirroring `performRowUpdate(for:_:)`'s existing shape), since only one
row-action sheet or dialog can be open at a time. `TransactionDetailViewModel`
keeps only what is genuinely its own: event assign/remove, an *existing*
advance's delete/write-off/reopen and its reimbursements, and unlinking a
transfer. Its now-fully-dead `performUpdate(_:)` (its only caller,
`editManualTransaction`, moved out) and `ActionFailure.transactionInUse`
(its only producer, `deleteManualTransaction`, moved out) are removed with
it, along with the `onDelete` closure threaded from `TransactionRow` through
`TransactionDetailView`/`TransactionDetailViewModel`/`TransactionDetailLoader`
— it existed solely to dismiss the detail screen after a delete made
*there*, which no longer happens.

**`TransactionDetailView` keeps its `categories` parameter**, a deviation
from this ADR's original plan (which called for dropping it along with
`onRulesApplied`). The header still needs a category name to show, and the
Anticipi entry path (`TransactionDetailLoader`) has no category list of its
own to hand in — it passes `categories: []` and relies on
`loadCategoriesIfNeeded()` (the one method left in
`TransactionDetailViewModel+Category.swift`) to fetch on demand. Dropping the
parameter would leave the header blank on that path until the fetch
resolves; keeping it costs nothing since Movimenti already has the list in
hand.

## Consequences

- Categorizing a Movimenti row is two taps, from anywhere in the list.
- **An advance opened from the Anticipi tab no longer has an in-place
  categorize action** — categorization now only exists on the Movimenti row.
  Accepted as the same kind of narrowing the categorization move already
  made; if it proves wrong in practice, "Segna come anticipo" already
  demonstrated a Movimenti-row-only advance action is livable.
- **A manual-account advance opened from Anticipi/PersonDetail also loses
  its edit/delete affordance** on that screen (it moved to the Movimenti row
  only) — a narrower edge case (manual account *and* advance together) than
  the categorization one, accepted for the same reason.
- The toolbar's `Menu` is gone; "Filtri" and "+" are the only two actions
  left there.
- `docs/design/tokens.md`'s "Loading and press feedback" section gets a
  short note on the long-press idiom.
- `tasks/backlog.md`'s "Movimenti/Dettaglio rethink" item closes;
  `tasks/done.md` gets a new entry. The pre-existing, unrelated note that
  `TransactionDetailLoader` passes `events: []` (so the event chip isn't
  navigable from the Anticipi path) stays open — untouched by this change.

## Alternatives considered

- **A bottom sheet instead of `.contextMenu` for the row's secondary
  actions.** Rejected: a context menu is the platform-standard gesture for
  "more actions on this specific item" and needs no new chrome; a sheet
  would have needed its own dismiss affordance and design pass for a menu
  that's just a list of five labeled actions.
- **Disable inapplicable menu entries instead of hiding them** (e.g. show
  "Segna come anticipo" greyed out on an ineligible row). Rejected: a
  five-entry menu where two are routinely greyed out reads as noisier than
  a shorter menu that only ever shows what's possible — consistent with how
  `TransactionRow.Selection.isSelectable` already handles the analogous case
  in selection mode by disabling rather than hiding, which is the right call
  there specifically because the row's identity must stay stable while the
  user is mid-selection; a closed menu has no such constraint.
- **Keep "Collega trasferimento" in the toolbar and add the row menu
  alongside it.** Rejected: the whole point was that the toolbar's `Menu`
  was a one-entry service menu; keeping it (now redundant with "Collega a…")
  would have shipped two entry points for the same action instead of one.

## Revisit when

- The on-device pass (this ADR's own long-press idiom, folded into
  `tasks/backlog.md` item 13) judges: whether long-press fights
  `.matchedTransitionSource`/`.navigationTransition(.zoom(...))` on the same
  row; whether the context-menu preview clips correctly on a row inside a
  `Card` at `contentPadding: 0`; whether the leading-tile tap target ever
  steals a tap meant for the `NavigationLink` or vice versa (the most
  fragile seam in this whole change); and whether the dashed
  "da categorizzare" tile actually reads as tappable at a glance.
- Advances gets its own detail screen (long discussed, never built) — at
  that point `TransactionDetailView` could narrow further, or the
  categorize-from-Anticipi gap this ADR accepts could be revisited on its
  own screen instead.
