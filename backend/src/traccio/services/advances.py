"""Resolve each advance transaction's signed spending share for a projection.

An advance transaction's ``effective_amount`` is not its raw ``money`` — it is
the user's declared ``own_share``, adjusted for reimbursements received and any
write-off (see :func:`~traccio.domain.advances.derive_advance`). Several
read-side projections (the transaction list, an event's total, and the
dashboard summary) need this same signed share resolved once per advance
transaction before they can sum ``effective_amount`` correctly. This module
holds that one resolution so it is written, tested, and reused in exactly one
place rather than reimplemented per endpoint.

This module is pure (no I/O) and imports only ``domain``.
"""

from collections.abc import Mapping, Sequence
from uuid import UUID

from traccio.domain.advances import derive_advance
from traccio.domain.enums import AdvanceStatus, TransactionRole
from traccio.domain.models import Advance, Transaction
from traccio.domain.money import Money


def spending_shares(
    transactions: Sequence[Transaction],
    *,
    advance_by_tx: Mapping[UUID, Advance],
    reimbursed: Mapping[UUID, Money],
) -> dict[UUID, Money]:
    """Return each advance transaction's signed spending share, keyed by tx id.

    For every transaction whose ``role`` is
    :attr:`~traccio.domain.enums.TransactionRole.ADVANCE`, resolves its linked
    :class:`~traccio.domain.models.Advance` and the total reimbursed against it,
    then derives the signed share via
    :func:`~traccio.domain.advances.derive_advance` (which accounts for a
    write-off moving the outstanding amount back into spending). Non-advance
    transactions, and advance transactions with no matching row in
    ``advance_by_tx`` (should not happen — ``role=advance`` is only ever set
    alongside an ``Advance`` row — but handled by omission rather than a raised
    error), are simply absent from the result.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The transactions to resolve shares for. Only ``role=advance`` members
        contribute an entry to the result.
    advance_by_tx : Mapping[UUID, Advance]
        Each advance, keyed by its linked transaction id.
    reimbursed : Mapping[UUID, Money]
        The sum reimbursed so far, keyed by advance id. An advance absent from
        this mapping is treated as having no reimbursements yet.

    Returns
    -------
    dict[UUID, Money]
        The signed spending share for each advance transaction, keyed by
        transaction id — exactly what
        :func:`~traccio.domain.effective_amount.effective_amount` consumes as
        ``advance_own_share`` for an ``advance`` role.
    """
    shares: dict[UUID, Money] = {}
    for transaction in transactions:
        if transaction.role is not TransactionRole.ADVANCE:
            continue
        advance = advance_by_tx.get(transaction.id)
        if advance is None:
            continue
        currency = advance.own_share.currency
        received = reimbursed.get(advance.id, Money(amount=0, currency=currency))
        state = derive_advance(
            transaction,
            advance.own_share,
            received,
            written_off=advance.status is AdvanceStatus.WRITTEN_OFF,
        )
        shares[transaction.id] = state.spending_share
    return shares
