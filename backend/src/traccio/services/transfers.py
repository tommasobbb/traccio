"""Transfer detection: suggest, never link.

A transfer is two transactions representing the same money moving between two of
the user's own accounts; neither leg is income or spending (see
``docs/domain.md``). No bank marks a movement as internal, so it must be
detected. Per the architecture invariant, **detection never mutates**: this
module only *suggests* candidate pairs — an explicit user action later sets
``role=transfer`` on both legs. A wrongly linked transfer erases a real expense,
which is worse than missing one, so nothing here writes.

This module is pure (no I/O) and imports only ``domain``.
"""

from collections.abc import Collection, Mapping, Sequence
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from traccio.domain.enums import AccountKind, TransactionRole, TransactionStatus, TransferKind
from traccio.domain.models import Transaction

# Default matching tolerances. Tunable via ``Settings`` at the call site (the
# endpoint passes the configured values in); these keep the pure function usable
# without a settings object, e.g. in unit tests.
_DEFAULT_AMOUNT_TOLERANCE_CENTS = 100
_DEFAULT_WINDOW_DAYS = 4
# Funded-payment legs match on an exact amount by default — a card-funded wallet
# payment carries no fee or FX drift between the legs.
_DEFAULT_FUNDING_AMOUNT_TOLERANCE_CENTS = 0

# Stable, value-free reason codes for an invalid transfer pair. Exposed so the
# API layer can map a rejection to an HTTP status without parsing a message.
REASON_SAME_ACCOUNT = "same_account"
REASON_CURRENCY_MISMATCH = "currency_mismatch"
REASON_NOT_OPPOSITE_SIGNS = "not_opposite_signs"
REASON_NOT_TWO_OUTFLOWS = "not_two_outflows"
REASON_NOT_PERSONAL = "not_personal"
REASON_REJECTED = "rejected"
REASON_ZERO_AMOUNT = "zero_amount"


class TransferPairError(ValueError):
    """A pair of transactions cannot form a transfer.

    Raised by :func:`validate_transfer_pair`. Carries a stable, value-free
    ``reason`` (one of the ``REASON_*`` constants) so the API layer can map it to
    an HTTP status without inspecting the message. No amounts, descriptions, or
    other financial values are included (see ``.claude/rules/data-safety.md``).

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"invalid transfer pair: {reason}")
        self.reason = reason


class TransferSuggestion(BaseModel):
    """A suggested transfer linking two transactions the user may confirm.

    A suggestion, not the persisted ``Transfer`` entity: it carries no id and
    nothing is written until the user confirms.

    ``kind`` decides what the two legs mean:

    - :attr:`TransferKind.TWO_SIDED` — ``outgoing`` is the negative leg (money
      left an account), ``incoming`` the positive leg (money arrived).
    - :attr:`TransferKind.FUNDED_PAYMENT` — both legs are outflows. ``outgoing``
      is the funding leg (a card charge that will be zeroed on confirm),
      ``incoming`` is the funded leg on a wallet account (the real purchase,
      left ``personal``). Both ``*_amount`` values are negative here.

    Attributes
    ----------
    kind : TransferKind
        The pairing this suggests.
    outgoing_transaction_id : UUID
        Two-sided: the negative leg. Funded payment: the funding leg.
    incoming_transaction_id : UUID
        Two-sided: the positive leg. Funded payment: the funded (wallet) leg.
    currency : str
        ISO 4217 code shared by both legs (a transfer is single-currency).
    outgoing_amount : int
        The outgoing leg's amount in minor units. Negative for both kinds.
    incoming_amount : int
        The incoming leg's amount in minor units. Positive for a two-sided
        transfer, negative for a funded payment.
    amount_delta : int
        Absolute difference between the legs' magnitudes (``>= 0``); zero when
        they match exactly. A small non-zero value is a fee or rounding.
    day_gap : int
        Whole days between the legs' effective dates (``>= 0``); settlement is
        not simultaneous.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    kind: TransferKind = TransferKind.TWO_SIDED
    outgoing_transaction_id: UUID
    incoming_transaction_id: UUID
    currency: str
    outgoing_amount: int
    incoming_amount: int
    amount_delta: int
    day_gap: int


def _effective_date(transaction: Transaction) -> datetime | None:
    """Return the date a transaction is dated by, or ``None`` if it has neither.

    Prefers ``booked_at`` (settlement) and falls back to ``value_date``, the same
    coalescing the transaction listing orders by.
    """
    return transaction.booked_at or transaction.value_date


def detect_transfers(
    transactions: Sequence[Transaction],
    *,
    amount_tolerance_cents: int = _DEFAULT_AMOUNT_TOLERANCE_CENTS,
    window_days: int = _DEFAULT_WINDOW_DAYS,
    funding_amount_tolerance_cents: int = _DEFAULT_FUNDING_AMOUNT_TOLERANCE_CENTS,
    account_kinds: Mapping[UUID, AccountKind] | None = None,
    dismissed_pairs: Collection[frozenset[UUID]] = (),
) -> list[TransferSuggestion]:
    """Suggest transfers among ``transactions``, of both kinds.

    Considers only reviewable candidates — ``personal`` role, not ``rejected``,
    with a usable effective date and a non-zero amount — so a confirmed role is
    never re-suggested and a movement that never settled is ignored. Every
    candidate pair on different accounts, sharing a currency, and within
    ``window_days`` is then classified by sign:

    - **Opposite signs** → a :attr:`TransferKind.TWO_SIDED` transfer, if the
      magnitudes differ by at most ``amount_tolerance_cents``.
    - **Both outflows** → a :attr:`TransferKind.FUNDED_PAYMENT`, if the
      magnitudes differ by at most ``funding_amount_tolerance_cents`` *and*
      exactly one leg sits on a ``wallet`` account (per ``account_kinds``). The
      wallet leg is the real purchase (kept ``personal``); the other funds it.
      Without that wallet signal the pair is not suggested — a user may still
      link it explicitly.

    Both kinds compete in **one** greedy, one-to-one assignment ranked by
    closeness (amount difference, then day gap, then two-sided before funded,
    then transaction id for a total order), so no transaction appears in two
    suggestions. A leg with no counterpart (a half-transfer to an unconnected
    account) simply yields nothing.

    The candidate pairs are found with a forward window rather than an
    every-pair scan: candidates are sorted by effective date and each is
    compared only with the following ones until the day gap exceeds
    ``window_days`` (ADR 0025). The pairs considered are exactly those an
    every-pair scan would keep; the change only avoids building the ones it
    would immediately discard, which kept detection from degrading
    quadratically once it ran over full account history.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The pool to search, typically all of one user's transactions.
    amount_tolerance_cents : int, optional
        Maximum absolute difference between an opposite-sign pair's magnitudes,
        in minor units. Absorbs fees on same-currency internal moves.
    window_days : int, optional
        Maximum whole-day gap between the legs' effective dates. Applies to both
        kinds.
    funding_amount_tolerance_cents : int, optional
        Maximum absolute difference between a funded payment's two outflows.
        Defaults to ``0`` — a card-funded wallet payment is charged exactly.
    account_kinds : Mapping[UUID, AccountKind] or None, optional
        Account id → kind, used only to spot the wallet leg of a funded
        payment. Absent or empty disables funded-payment suggestions.
    dismissed_pairs : Collection[frozenset[UUID]], optional
        Unordered id pairs the user has rejected; any candidate pair whose two
        ids form one of these is skipped, for either kind. Defaults to none.

    Returns
    -------
    list[TransferSuggestion]
        The suggested pairs, most confident first. Empty when nothing matches.
    """
    kinds = dict(account_kinds or {})

    # Reviewable candidates only: a confirmed role is never re-suggested, a
    # rejected movement never settled, and we need a date and a real amount. The
    # effective date is carried alongside each so it is never recomputed or
    # re-checked for None below.
    candidates: list[tuple[Transaction, datetime]] = []
    for tx in transactions:
        date = _effective_date(tx)
        if (
            tx.role is TransactionRole.PERSONAL
            and tx.status is not TransactionStatus.REJECTED
            and date is not None
            and tx.money.amount != 0
        ):
            candidates.append((tx, date))

    dismissed = set(dismissed_pairs)

    # Sorted by effective date so the day window is a contiguous forward slice:
    # the inner scan can stop (not just skip) once the gap passes window_days.
    candidates.sort(key=lambda item: item[1])

    # (amount_delta, day_gap, kind_rank, out_id, in_id, suggestion) — kind_rank
    # orders a two-sided pair (0) ahead of a funded-payment guess (1) on a tie,
    # the two ids give a total order so the greedy pass below is deterministic
    # regardless of the order pairs were discovered in.
    scored: list[tuple[int, int, int, str, str, TransferSuggestion]] = []
    for i in range(len(candidates)):
        first, first_date = candidates[i]
        for j in range(i + 1, len(candidates)):
            second, second_date = candidates[j]
            day_gap = (second_date - first_date).days
            if day_gap > window_days:
                break
            if first.account_id == second.account_id:
                continue
            if first.money.currency != second.money.currency:
                continue
            if frozenset({first.id, second.id}) in dismissed:
                continue
            amount_delta = abs(abs(first.money.amount) - abs(second.money.amount))

            first_negative = first.money.amount < 0
            second_negative = second.money.amount < 0

            if first_negative != second_negative:
                # Opposite signs -> a classic two-sided transfer.
                if amount_delta > amount_tolerance_cents:
                    continue
                outgoing, incoming = (first, second) if first_negative else (second, first)
                kind = TransferKind.TWO_SIDED
            elif first_negative and second_negative:
                # Two outflows -> only a funded payment, and only when exactly
                # one leg is on a wallet: that leg is the real purchase, the
                # other one funds it. Without that signal we cannot tell which
                # is which.
                if amount_delta > funding_amount_tolerance_cents:
                    continue
                first_wallet = kinds.get(first.account_id) is AccountKind.WALLET
                second_wallet = kinds.get(second.account_id) is AccountKind.WALLET
                if first_wallet == second_wallet:
                    continue
                incoming, outgoing = (first, second) if first_wallet else (second, first)
                kind = TransferKind.FUNDED_PAYMENT
            else:
                # Two inflows are never a transfer of either kind.
                continue

            scored.append(
                (
                    amount_delta,
                    day_gap,
                    0 if kind is TransferKind.TWO_SIDED else 1,
                    str(outgoing.id),
                    str(incoming.id),
                    TransferSuggestion(
                        kind=kind,
                        outgoing_transaction_id=outgoing.id,
                        incoming_transaction_id=incoming.id,
                        currency=outgoing.money.currency,
                        outgoing_amount=outgoing.money.amount,
                        incoming_amount=incoming.money.amount,
                        amount_delta=amount_delta,
                        day_gap=day_gap,
                    ),
                )
            )

    # Rank by closeness, then assign greedily so each transaction appears once.
    scored.sort(key=lambda item: (item[0], item[1], item[2], item[3], item[4]))
    used: set[UUID] = set()
    suggestions: list[TransferSuggestion] = []
    for *_, suggestion in scored:
        if suggestion.outgoing_transaction_id in used or suggestion.incoming_transaction_id in used:
            continue
        used.add(suggestion.outgoing_transaction_id)
        used.add(suggestion.incoming_transaction_id)
        suggestions.append(suggestion)

    return suggestions


def validate_transfer_pair(
    outgoing: Transaction,
    incoming: Transaction,
    *,
    kind: TransferKind = TransferKind.TWO_SIDED,
) -> None:
    """Check that two transactions may be confirmed as a transfer of ``kind``.

    Enforces the structural invariants a transfer must satisfy — different
    accounts, shared currency, both still ``personal``, neither ``rejected``,
    non-zero amounts — plus a sign rule that depends on ``kind``:

    - :attr:`TransferKind.TWO_SIDED` — ``outgoing`` negative, ``incoming``
      positive (opposite signs).
    - :attr:`TransferKind.FUNDED_PAYMENT` — **both** legs negative (two
      outflows); ``outgoing`` is the funding leg, ``incoming`` the funded one.

    It deliberately does **not** apply the amount tolerance or day window: those
    bound *automatic suggestions*, whereas an explicit user confirmation may
    link any structurally valid pair. Sharing this function with detection keeps
    the confirm rule and the suggestion rule from drifting apart.

    Parameters
    ----------
    outgoing : Transaction
        Two-sided: the negative leg. Funded payment: the funding leg (negative).
    incoming : Transaction
        Two-sided: the positive leg. Funded payment: the funded leg (negative).
    kind : TransferKind, optional
        Which pairing to validate for. Defaults to
        :attr:`TransferKind.TWO_SIDED`.

    Raises
    ------
    TransferPairError
        If the pair violates any invariant. The exception's ``reason`` is a
        stable, value-free code (a module ``REASON_*`` constant); no financial
        values are included.
    """
    if outgoing.account_id == incoming.account_id:
        raise TransferPairError(REASON_SAME_ACCOUNT)
    if outgoing.money.currency != incoming.money.currency:
        raise TransferPairError(REASON_CURRENCY_MISMATCH)
    for leg in (outgoing, incoming):
        if leg.status is TransactionStatus.REJECTED:
            raise TransferPairError(REASON_REJECTED)
        if leg.role is not TransactionRole.PERSONAL:
            raise TransferPairError(REASON_NOT_PERSONAL)
        if leg.money.amount == 0:
            raise TransferPairError(REASON_ZERO_AMOUNT)
    if kind is TransferKind.FUNDED_PAYMENT:
        if not (outgoing.money.amount < 0 and incoming.money.amount < 0):
            raise TransferPairError(REASON_NOT_TWO_OUTFLOWS)
    elif not (outgoing.money.amount < 0 and incoming.money.amount > 0):
        raise TransferPairError(REASON_NOT_OPPOSITE_SIGNS)
