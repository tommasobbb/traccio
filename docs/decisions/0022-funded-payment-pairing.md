# 0022 — Funded payments: pairing two outflows so a card-funded wallet spend counts once

Status: accepted
Date: 2026-08-30

## Context

Real daily use surfaced a class of double-counted spending the transfer
model could not represent. When PayPal charges a linked Revolut card
instead of drawing on its own balance, **two** movements land in Traccio,
both outflows:

- the Revolut card charge (`DBIT`), on a `current`/`card` account;
- the PayPal payment to the merchant (`DBIT`), on the `wallet` account.

PayPal never reports the top-up as its own credit, so there is no
opposite-sign leg. The existing `Transfer` requires opposite signs
(`validate_transfer_pair` raised `not_opposite_signs`; `detect_transfers`
skipped same-sign pairs; the client's `canLinkAsTransfer` made the second
row unselectable). The pair was therefore invisible everywhere and both
rows kept `role=personal`, so the dashboard added the amount twice.

`TransactionRole.TRANSFER` is also the wrong primitive here: it zeroes
**both** legs. Zeroing both outflows would erase the expense entirely
instead of de-duplicating it — the real purchase must survive, with its
merchant and category intact.

## Decision

**1. Extend `Transfer`, do not add a parallel entity.** A `funded_payment`
is a transfer whose incoming leg the bank never reported. The pairing
table, the `(user_id, outgoing, incoming)` uniqueness, `transfer_dismissals`,
the confirm/reject/delete endpoints and the client's pick-two flow are all
reused. `Transfer` gains a `kind` column (`TransferKind`: `two_sided` |
`funded_payment`), backfilled to `two_sided` (migration `a7b8c9d0e1f2`,
`_enum_column` — `funding` and the two kind values fit existing widths).

**2. A new role, `TransactionRole.FUNDING`, that zeroes exactly one leg.**
`effective_amount` returns zero for `FUNDING` (the derivation stays the one
pure function — `docs/architecture.md`). On confirming a `funded_payment`,
only `outgoing_transaction_id` (the card charge) becomes `FUNDING`;
`incoming_transaction_id` (the real purchase) stays `PERSONAL` and keeps its
full amount, merchant, and category. Deleting the transfer reverts both legs
to `PERSONAL` regardless of kind (the funded leg's write is a no-op).

**3. The historical field names carry a per-kind meaning, not new columns.**
For `funded_payment`, `outgoing_transaction_id` = the funding leg and
`incoming_transaction_id` = the funded leg — both outflows. Renaming the
columns/model/mappers/schemas/client would be broad churn for a naming
nicety; the meaning is documented at every seam instead.

**4. Detection suggests a `funded_payment` only when exactly one leg is on a
`wallet` account.** That leg is the real purchase (`incoming`), the other
funds it (`outgoing`). Without a wallet signal detection cannot tell which
outflow funds which, so it proposes nothing — the user may still link any
same-sign pair explicitly. `detect_transfers` takes an
`account_kinds` map for this; the endpoint builds it from `list_accounts`.
Both kinds compete in one greedy assignment (ranked amount-delta, then
day-gap, then two-sided ahead of funded), so no transaction is in two
suggestions.

**5. An exact-amount tolerance for funded payments.** A card-funded wallet
payment is charged at exactly the payment amount — no fee or FX drift
between the legs — so `funding_amount_tolerance_cents` defaults to `0`,
separate from `transfer_amount_tolerance_cents` (100). The day window
(`transfer_window_days`) is shared. As for two-sided transfers,
`validate_transfer_pair` ignores both bounds — an explicit confirm may link
any structurally valid pair; the bounds only shape suggestions.

**6. `validate_transfer_pair` gains a `kind` argument.** Shared structural
checks are unchanged (different accounts, same currency, both `personal`,
neither `rejected`, non-zero). The sign rule branches: `two_sided` keeps
`not_opposite_signs`; `funded_payment` requires **both legs negative**
(`not_two_outflows`) — two inflows are never a funded payment.

## Consequences

- The dashboard needs no change: exclusion still flows only through
  `effective_amount` returning zero (`db/repositories.py` has no role
  predicate), which is exactly the mechanism `FUNDING` uses.
- `docs/domain.md` §Transfer now documents two kinds; the §Role table gains
  a `funding` row (zero, like `transfer`, but asymmetric).
- Client: new `TransferKind` model, `TransactionRole.funding`, `kind` on
  `TransferResponse`/`TransferSuggestionResponse`/`ConfirmTransferRequest`,
  and `confirmTransfer(…, kind:)`. The Trasferimenti suggestion card renders
  a `funded_payment` as "Doppia uscita" and confirms it with the
  backend's orientation. `TransactionRow` shows the `funding` leg as a muted
  "Ricarica" badge (it is already muted via `effective_amount == 0`).
- **Deferred, filed in `tasks/backlog.md`:** letting the pick-two selection
  mode in Movimenti link a same-sign pair (with a sheet to pick which leg is
  the top-up), and a dedicated "questa ricarica finanzia…" card on the
  funding leg's `TransactionDetailView`. Detection already orients the
  common case, so the suggestion path covers real use today.

## Alternatives considered

- **A separate `FundingLink` entity + its own detection/endpoints.**
  Rejected: it clones the pairing table, dismissals, confirm/reject, and the
  client picker for no gain; the only genuinely new primitive is the
  one-sided zeroing, which is a role.
- **Reuse `TransactionRole.TRANSFER` for the funding leg.** Rejected: it
  zeroes both legs, erasing the real expense instead of de-duplicating it.
- **A boolean `is_funded_payment` instead of an enum.** Rejected: an enum
  leaves room for a third kind and reads better at every call site; the
  column is `VARCHAR`, so the width cost is nil.
- **Orient funded-payment suggestions by date/id instead of account kind.**
  Rejected: unreliable. Requiring a wallet leg keeps suggestions
  high-precision ("a wrongly detected transfer erases a real expense",
  `docs/domain.md` §Transfer).

## Revisit when

- A second wallet-style provider lands (M4) and "exactly one wallet leg"
  needs to become "exactly one leg whose account is more liquid than the
  other" or similar.
- A funded payment is seen with a real amount gap (a wallet FX conversion on
  the purchase leg) — then `funding_amount_tolerance_cents` earns a non-zero
  default.
