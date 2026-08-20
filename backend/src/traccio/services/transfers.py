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

from collections.abc import Sequence
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

    scored: list[tuple[int, int, TransferSuggestion]] = []
    for (first, first_date), (second, second_date) in combinations(candidates, 2):
        if first.account_id == second.account_id:
            continue
        if first.money.currency != second.money.currency:
            continue
        # Opposite signs: exactly one leg is negative.
        if (first.money.amount < 0) == (second.money.amount < 0):
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
