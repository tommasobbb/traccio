"""Transactions endpoint router."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.transactions import TransactionResponse, TransactionsResponse
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    list_advances,
    list_transactions,
    sum_reimbursements_by_advance,
)
from traccio.db.session import get_session
from traccio.domain.advances import derive_advance
from traccio.domain.enums import AdvanceStatus, TransactionRole
from traccio.domain.models import Advance
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
    # An advance transaction's effective_amount is its derived spending share,
    # which depends on the declared own_share, the reimbursements received, and
    # whether the advance was written off (a write-off moves the outstanding
    # amount into spending). Map each advanced transaction to its Advance and the
    # reimbursed total so the projection can derive the signed share once per row.
    # (role=advance is only ever set alongside an Advance row, so the map is
    # always consistent — see the advances router.)
    advance_by_tx: dict[UUID, Advance] = {
        advance.transaction_id: advance for advance in list_advances(session, user_id)
    }
    reimbursed_by_advance = sum_reimbursements_by_advance(session, user_id)

    responses: list[TransactionResponse] = []
    for transaction in found:
        share: Money | None = None
        if transaction.role is TransactionRole.ADVANCE:
            advance = advance_by_tx.get(transaction.id)
            if advance is not None:
                currency = advance.own_share.currency
                reimbursed = reimbursed_by_advance.get(
                    advance.id, Money(amount=0, currency=currency)
                )
                state = derive_advance(
                    transaction,
                    advance.own_share,
                    reimbursed,
                    written_off=advance.status is AdvanceStatus.WRITTEN_OFF,
                )
                share = state.spending_share
        responses.append(TransactionResponse.from_domain(transaction, advance_own_share=share))

    # Log a count, never transaction contents (see data-safety rules).
    logger.info("transactions.list", count=len(responses))
    return TransactionsResponse(transactions=responses)
