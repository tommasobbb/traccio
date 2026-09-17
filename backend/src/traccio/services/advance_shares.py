"""Fetch a user's advance pool and resolve spending shares for a projection.

The read-side counterpart to :mod:`traccio.services.advances` (which is pure
and holds only :func:`~traccio.services.advances.spending_shares` itself):
this module does the I/O that function needs — listing the user's advances
and their reimbursement totals — before calling it. Before this module
existed, four endpoints each fetched the same two user-wide collections and
called ``spending_shares`` themselves: the transaction list, one
transaction's detail, the dashboard summary, and the event list/detail
endpoints. A fifth that forgot this block would silently report an advance's
full charge as spending instead of the user's declared share.

Imports ``domain`` and ``db``, like every other I/O-touching ``services/``
module.
"""

from collections.abc import Sequence
from uuid import UUID

from sqlalchemy.orm import Session

from traccio.db.repositories import list_advances, sum_reimbursements_by_advance
from traccio.domain.models import Advance, Transaction
from traccio.domain.money import Money
from traccio.services.advances import spending_shares


def fetch_advance_pool(
    session: Session, *, user_id: UUID
) -> tuple[dict[UUID, Advance], dict[UUID, Money]]:
    """Fetch the raw ``(advance_by_tx, reimbursed)`` pair ``spending_shares`` needs.

    Split out from :func:`resolve_advance_shares` for a caller that resolves
    shares for more than one list of transactions in the same request (the
    dashboard summary's current period and its comparison period) and would
    otherwise fetch this identical, user-wide pair twice.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advances; both queries are scoped to it.

    Returns
    -------
    tuple[dict[UUID, Advance], dict[UUID, Money]]
        Every advance keyed by its transaction id, and the total reimbursed
        against each, keyed by advance id — exactly
        :func:`~traccio.services.advances.spending_shares`'s
        ``advance_by_tx``/``reimbursed`` parameters.
    """
    advance_by_tx = {advance.transaction_id: advance for advance in list_advances(session, user_id)}
    reimbursed = sum_reimbursements_by_advance(session, user_id)
    return advance_by_tx, reimbursed


def resolve_advance_shares(
    session: Session, *, user_id: UUID, transactions: Sequence[Transaction]
) -> dict[UUID, Money]:
    """Fetch the user's advances and reimbursements, then resolve each share.

    The common case: a caller resolving shares for exactly one list of
    transactions. A caller that needs to do this more than once per request
    uses :func:`fetch_advance_pool` directly instead, to fetch only once.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advances; both queries are scoped to it.
    transactions : Sequence[Transaction]
        The transactions to resolve a share for — only those with
        ``role=advance`` and a matching row in the fetched pool get a
        non-default entry (see :func:`~traccio.services.advances.spending_shares`).

    Returns
    -------
    dict[UUID, Money]
        Each advance transaction's signed spending share, keyed by
        transaction id.
    """
    advance_by_tx, reimbursed = fetch_advance_pool(session, user_id=user_id)
    return spending_shares(transactions, advance_by_tx=advance_by_tx, reimbursed=reimbursed)
