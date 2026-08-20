"""Transactions endpoint router."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.transactions import TransactionResponse, TransactionsResponse
from traccio.core.logging import get_logger
from traccio.db.repositories import list_advances, list_transactions
from traccio.db.session import get_session
from traccio.domain.advances import advance_spending_share
from traccio.domain.enums import TransactionRole
from traccio.domain.money import Money

logger = get_logger(__name__)

router = APIRouter()


@router.get("/transactions", response_model=TransactionsResponse)
def transactions(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    account_id: Annotated[UUID | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> TransactionsResponse:
    """List the current user's transactions, most recent first.

    Scoped to the current user (see :func:`~traccio.api.deps.current_user_id`);
    the underlying query is already ``scoped by user_id``. The optional
    ``account_id`` narrows the result to one account but is always combined with
    ``user_id``, so it cannot reach another user's rows. ``limit``/``offset``
    page the result.

    Parameters
    ----------
    session : Session
        Request-scoped database session (see :func:`get_session`).
    user_id : UUID
        The user whose transactions to return.
    account_id : UUID or None, optional
        When given, restrict to this account.
    limit : int, optional
        Page size, between 1 and 200 (default 50).
    offset : int, optional
        Number of rows to skip (default 0).

    Returns
    -------
    TransactionsResponse
        The requested page of the user's transactions, most recent first.
    """
    found = list_transactions(session, user_id, account_id=account_id, limit=limit, offset=offset)
    # An advance transaction's effective_amount needs its declared own_share; map
    # each advanced transaction to its share so the projection can thread it in.
    # (role=advance is only ever set alongside an Advance row, so the map is
    # always consistent — see the advances router.)
    own_share_by_tx: dict[UUID, Money] = {
        advance.transaction_id: advance.own_share for advance in list_advances(session, user_id)
    }

    responses: list[TransactionResponse] = []
    for transaction in found:
        share: Money | None = None
        if transaction.role is TransactionRole.ADVANCE:
            own_share = own_share_by_tx.get(transaction.id)
            if own_share is not None:
                share = advance_spending_share(transaction, own_share)
        responses.append(TransactionResponse.from_domain(transaction, advance_own_share=share))

    # Log a count, never transaction contents (see data-safety rules).
    logger.info("transactions.list", count=len(responses))
    return TransactionsResponse(transactions=responses)
