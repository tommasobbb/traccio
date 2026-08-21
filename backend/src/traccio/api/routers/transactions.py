"""Transactions endpoint router.

Also carries the category-confirming endpoints
(``POST``/``DELETE /transactions/{id}/category``): the path prefix owns the
router, the same rule that puts ``/events/{id}/transactions`` on the events
router rather than here (see ``api/routers/events.py``).
"""

from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.transactions import (
    ConfirmCategoryRequest,
    PrunePendingResponse,
    TransactionResponse,
    TransactionsResponse,
)
from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    get_category,
    get_transaction,
    list_advances,
    list_transactions,
    prune_stale_pending_transactions,
    set_confirmed_category,
    sum_reimbursements_by_advance,
)
from traccio.db.session import get_session
from traccio.domain.models import Advance
from traccio.services.advances import spending_shares

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
    # amount into spending). Resolve each advanced transaction's signed share
    # once per row (role=advance is only ever set alongside an Advance row, so
    # the map is always consistent — see the advances router).
    advance_by_tx: dict[UUID, Advance] = {
        advance.transaction_id: advance for advance in list_advances(session, user_id)
    }
    reimbursed_by_advance = sum_reimbursements_by_advance(session, user_id)
    shares = spending_shares(found, advance_by_tx=advance_by_tx, reimbursed=reimbursed_by_advance)

    responses = [
        TransactionResponse.from_domain(transaction, advance_own_share=shares.get(transaction.id))
        for transaction in found
    ]

    # Log a count, never transaction contents (see data-safety rules).
    logger.info("transactions.list", count=len(responses))
    return TransactionsResponse(transactions=responses)


@router.post("/transactions/{transaction_id}/category", status_code=status.HTTP_204_NO_CONTENT)
def confirm_transaction_category(
    transaction_id: UUID,
    body: ConfirmCategoryRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Confirm a category on a transaction — the explicit user action.

    Sets ``confirmed_category_id`` via
    :func:`~traccio.db.repositories.set_confirmed_category` — the only writer
    of that column — which then wins over any suggestion in the derived
    ``effective_category_id`` (see
    :func:`~traccio.domain.categories.effective_category`). A ``404`` if the
    transaction or the category is unknown or not the caller's — a stranger's
    category id is indistinguishable from an unknown one, so this doubles as
    the cross-user gate.

    Parameters
    ----------
    transaction_id : UUID
        The transaction to categorize.
    body : ConfirmCategoryRequest
        The category to confirm.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user both the transaction and category belong to.
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="unknown transaction")
    category = get_category(session, user_id=user_id, category_id=body.category_id)
    if category is None:
        raise HTTPException(status_code=404, detail="unknown category")

    set_confirmed_category(
        session, user_id=user_id, transaction_id=transaction_id, category_id=body.category_id
    )
    session.commit()
    logger.info("transactions.confirm_category", transaction_id=str(transaction_id))


@router.delete("/transactions/{transaction_id}/category", status_code=status.HTTP_204_NO_CONTENT)
def clear_transaction_category(
    transaction_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Clear a transaction's confirmed category, falling back to any suggestion.

    Idempotent: clearing when nothing is confirmed still succeeds (a ``409`` is
    never raised for "already clear"). A ``404`` if the transaction is unknown
    or not the caller's.

    Parameters
    ----------
    transaction_id : UUID
        The transaction to clear.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transaction belongs to.
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="unknown transaction")

    set_confirmed_category(
        session, user_id=user_id, transaction_id=transaction_id, category_id=None
    )
    session.commit()
    logger.info("transactions.clear_category", transaction_id=str(transaction_id))


@router.post("/transactions/prune-pending", response_model=PrunePendingResponse)
def prune_pending_transactions(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> PrunePendingResponse:
    """Delete abandoned pending transactions, per ``docs/domain.md``.

    "Pending transactions that neither settle nor reappear within a defined
    window are dropped, not kept as ghosts." Explicit and on-demand — like
    ``POST /rules/apply`` (ADR 0005) — rather than wired into sync, until a
    background scheduler (M3) makes that worth the added write path inside
    sync. Never touches a row the user has acted on: see
    :func:`~traccio.db.repositories.prune_stale_pending_transactions` for the
    full eligibility rule (still ``pending``, unseen by a sync for
    ``Settings.pending_transaction_ttl_days``, still ``personal``, not in an
    event, no confirmed category).

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose pending transactions to prune.

    Returns
    -------
    PrunePendingResponse
        How many rows were deleted.
    """
    cutoff = datetime.now(UTC) - timedelta(days=get_settings().pending_transaction_ttl_days)
    pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=cutoff)
    session.commit()

    # Log a count, never row contents (see data-safety rules).
    logger.info("transactions.prune_pending", pruned=pruned)
    return PrunePendingResponse(pruned=pruned)
