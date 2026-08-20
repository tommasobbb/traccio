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

from collections.abc import Collection, Sequence
from datetime import datetime
from itertools import combinations
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from traccio.domain.enums import TransactionRole, TransactionStatus
from traccio.domain.models import Transaction

# Default matching tolerances. Tunable via ``Settings`` at the call site (the
# endpoint passes the configured values in); these keep the pure function usable
# without a settings object, e.g. in unit tests.
_DEFAULT_AMOUNT_TOLERANCE_CENTS = 100
_DEFAULT_WINDOW_DAYS = 4

# Stable, value-free reason codes for an invalid transfer pair. Exposed so the
# API layer can map a rejection to an HTTP status without parsing a message.
REASON_SAME_ACCOUNT = "same_account"
REASON_CURRENCY_MISMATCH = "currency_mismatch"
REASON_NOT_OPPOSITE_SIGNS = "not_opposite_signs"
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
    nothing is written until the user confirms. The legs are named by sign — the
    outgoing (negative) leg left one account and the incoming (positive) leg
    arrived in another.

    Attributes
    ----------
    outgoing_transaction_id : UUID
        The negative leg (money left an account).
    incoming_transaction_id : UUID
        The positive leg (money arrived in another account).
    currency : str
        ISO 4217 code shared by both legs (a transfer is single-currency).
    outgoing_amount : int
        The outgoing leg's amount in minor units (negative).
    incoming_amount : int
        The incoming leg's amount in minor units (positive).
    amount_delta : int
        Absolute difference between the legs' magnitudes (``>= 0``); zero when
        they match exactly. A small non-zero value is a fee or rounding.
    day_gap : int
        Whole days between the legs' effective dates (``>= 0``); settlement is
        not simultaneous.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

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
    dismissed_pairs: Collection[frozenset[UUID]] = (),
) -> list[TransferSuggestion]:
    """Suggest transfers among ``transactions`` by pairing opposite legs.

    Considers only reviewable candidates — ``personal`` role, not ``rejected``,
    with a usable effective date and a non-zero amount — so a confirmed role is
    never re-suggested and a movement that never settled is ignored. Two
    candidates pair when they sit on different accounts, share a currency, have
    opposite signs, differ in magnitude by at most ``amount_tolerance_cents``,
    and fall within ``window_days`` of each other.

    Resolution is greedy and one-to-one: every qualifying pair is ranked by
    closeness (smallest amount difference, then smallest day gap) and each
    transaction is used at most once. A leg with no counterpart (a half-transfer
    to an unconnected account) simply yields nothing — that is normal, not an
    error.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The pool to search, typically all of one user's transactions.
    amount_tolerance_cents : int, optional
        Maximum allowed absolute difference between the legs' magnitudes, in
        minor units. Absorbs fees on same-currency internal moves.
    window_days : int, optional
        Maximum allowed whole-day gap between the legs' effective dates.
    dismissed_pairs : Collection[frozenset[UUID]], optional
        Unordered id pairs the user has rejected as transfers; any candidate pair
        whose two transaction ids form one of these is skipped, so a rejected
        suggestion is not proposed again. Defaults to none.

    Returns
    -------
    list[TransferSuggestion]
        The suggested pairs, most confident first (smallest amount difference,
        then smallest day gap). Empty when nothing matches.
    """
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
    scored: list[tuple[int, int, TransferSuggestion]] = []
    for (first, first_date), (second, second_date) in combinations(candidates, 2):
        if first.account_id == second.account_id:
            continue
        if first.money.currency != second.money.currency:
            continue
        # Opposite signs: exactly one leg is negative.
        if (first.money.amount < 0) == (second.money.amount < 0):
            continue
        if frozenset({first.id, second.id}) in dismissed:
            continue
        amount_delta = abs(abs(first.money.amount) - abs(second.money.amount))
        if amount_delta > amount_tolerance_cents:
            continue
        day_gap = abs((first_date - second_date).days)
        if day_gap > window_days:
            continue

        outgoing, incoming = (first, second) if first.money.amount < 0 else (second, first)
        scored.append(
            (
                amount_delta,
                day_gap,
                TransferSuggestion(
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
    scored.sort(key=lambda item: (item[0], item[1]))
    used: set[UUID] = set()
    suggestions: list[TransferSuggestion] = []
    for _, _, suggestion in scored:
        if suggestion.outgoing_transaction_id in used or suggestion.incoming_transaction_id in used:
            continue
        used.add(suggestion.outgoing_transaction_id)
        used.add(suggestion.incoming_transaction_id)
        suggestions.append(suggestion)

    return suggestions


def validate_transfer_pair(outgoing: Transaction, incoming: Transaction) -> None:
    """Check that two transactions may be confirmed as a transfer.

    Enforces the structural invariants a transfer must satisfy, the same ones
    :func:`detect_transfers` requires of a candidate pair — different accounts,
    shared currency, opposite signs (``outgoing`` negative, ``incoming``
    positive), both still ``personal``, neither ``rejected``, and non-zero
    amounts. It deliberately does **not** apply the amount tolerance or day
    window: those bound *automatic suggestions*, whereas an explicit user
    confirmation may link any structurally valid pair (a large fee or a slow
    settlement is the user's call to make).

    Sharing this function with detection keeps the confirm rule and the
    suggestion rule from drifting apart.

    Parameters
    ----------
    outgoing : Transaction
        The leg the user labelled as money leaving an account (must be negative).
    incoming : Transaction
        The leg the user labelled as money arriving (must be positive).

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
    if not (outgoing.money.amount < 0 and incoming.money.amount > 0):
        raise TransferPairError(REASON_NOT_OPPOSITE_SIGNS)
