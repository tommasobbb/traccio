"""Pure event aggregation: the net total of an event's members.

An :class:`~traccio.domain.models.Event` groups transactions from one occasion.
Its total is the sum of the members' ``effective_amount`` — so a transfer
between the user's own accounts contributes zero, an advance contributes only
the user's share, and a reimbursement contributes zero (see ``docs/domain.md``).
This is the whole point of an event: the *real* cost, not the gross outlay.

This module holds only the pure derivation — no I/O, imports only ``domain/`` —
so it is testable without a database and reused by the API layer, which resolves
each advance member's signed spending share (via
:func:`~traccio.domain.advances.derive_advance`) and passes it in through
``advance_shares``.

Scope (2026-08-21): the total is the single net figure. Breaking it down by
category is a later slice — categorization now exists
(:mod:`traccio.domain.categories`), which unblocks it in principle, but
extending :func:`event_total` to group members by category has not shipped
yet. See ``tasks/backlog.md`` §M2.
"""

from collections.abc import Mapping, Sequence
from uuid import UUID

from traccio.domain.effective_amount import effective_amount
from traccio.domain.enums import TransactionRole
from traccio.domain.models import Transaction
from traccio.domain.money import Money

# Stable, value-free reason code for an event whose members span more than one
# currency (see :class:`EventError`).
REASON_MIXED_CURRENCY = "mixed_currency"


class EventError(ValueError):
    """An event's members cannot be aggregated into a single total.

    Raised by :func:`event_total`. Carries a stable, value-free ``reason`` (a
    module ``REASON_*`` constant) so the API layer can map it to an HTTP status
    without inspecting the message. No financial values are included (see
    ``.claude/rules/data-safety.md``).

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"cannot total event: {reason}")
        self.reason = reason


def event_total(
    members: Sequence[Transaction],
    *,
    advance_shares: Mapping[UUID, Money] | None = None,
) -> Money | None:
    """Return the net total of an event's members, or ``None`` when empty.

    Sums :func:`~traccio.domain.effective_amount.effective_amount` over every
    member. An event has no inherent currency of its own, so the total's currency
    is taken from its members; an empty event therefore has no total and returns
    ``None``. All members must share one currency — there is no FX in Traccio, so
    a mixed-currency event cannot be summed into a single figure.

    Parameters
    ----------
    members : Sequence[Transaction]
        The transactions grouped under the event.
    advance_shares : Mapping[UUID, Money] or None, optional
        For each member whose ``role`` is
        :attr:`~traccio.domain.enums.TransactionRole.ADVANCE`, its **signed**
        spending share (see
        :func:`~traccio.domain.advances.advance_spending_share`), keyed by the
        transaction id. The caller derives these; they account for a write-off
        moving the outstanding amount back into spending. Ignored for every other
        role.

    Returns
    -------
    Money or None
        The net total in the members' shared currency, or ``None`` if the event
        has no members.

    Raises
    ------
    EventError
        If the members span more than one currency (``reason`` is
        :data:`REASON_MIXED_CURRENCY`).
    ValueError
        If a member is an advance but its share is missing from
        ``advance_shares`` (propagated from ``effective_amount``). The message is
        stable and value-free.
    """
    shares = advance_shares or {}

    total = 0
    currency: str | None = None
    for member in members:
        share = shares.get(member.id) if member.role is TransactionRole.ADVANCE else None
        effective = effective_amount(member, advance_own_share=share)
        if currency is None:
            currency = effective.currency
        elif effective.currency != currency:
            raise EventError(REASON_MIXED_CURRENCY)
        total += effective.amount

    return None if currency is None else Money(amount=total, currency=currency)
