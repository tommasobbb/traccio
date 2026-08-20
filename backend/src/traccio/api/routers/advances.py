"""Advance endpoints: create, read, and delete.

An advance is an explicit user action on one outgoing transaction: it records the
user's declared ``own_share`` and sets the transaction's ``role`` to ``advance``,
so only that share counts as spending (via the one pure ``effective_amount``
function). Deleting an advance reverts the transaction to ``personal``.

Reimbursements and the write-off flow are separate, later slices; an advance here
is always ``open`` with ``outstanding == receivable``.

Data safety (``.claude/rules/data-safety.md``): these handlers log only ids and
counts — never amounts or descriptions.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.advances import (
    AdvanceResponse,
    AdvancesResponse,
    CreateAdvanceRequest,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    advance_exists_for_transaction,
    create_advance,
    delete_advance,
    get_advance,
    get_transaction,
    list_advances,
    set_transaction_role,
)
from traccio.db.session import get_session
from traccio.domain.advances import AdvanceError, validate_advance
from traccio.domain.enums import TransactionRole
from traccio.domain.models import Advance, Participant, Transaction
from traccio.domain.money import Money

logger = get_logger(__name__)

router = APIRouter()


def _load_transaction(session: Session, *, user_id: UUID, transaction_id: UUID) -> Transaction:
    """Load a transaction owned by the user, or raise ``404``.

    Scoping is enforced by :func:`get_transaction`, so naming another user's (or
    an unknown) transaction is indistinguishable from "not found".
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="unknown transaction")
    return transaction


@router.post("/advances", response_model=AdvanceResponse, status_code=status.HTTP_201_CREATED)
def create_advance_endpoint(
    body: CreateAdvanceRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AdvanceResponse:
    """Create an advance on a transaction.

    Validates the transaction (the user's, ``personal``, not ``rejected``,
    outgoing) and the declared ``own_share`` (in range, in the transaction's
    currency), records the advance and its participants, and sets the
    transaction's ``role`` to ``advance``. Scoped to the current user.

    Parameters
    ----------
    body : CreateAdvanceRequest
        The transaction, the user's own share, and optional participants.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transaction belongs to.

    Returns
    -------
    AdvanceResponse
        The created advance, with derived receivable/outstanding.
    """
    transaction = _load_transaction(session, user_id=user_id, transaction_id=body.transaction_id)

    if advance_exists_for_transaction(session, user_id=user_id, transaction_id=transaction.id):
        raise HTTPException(status_code=409, detail="transaction already has an advance")

    # own_share and participant amounts are always in the transaction's currency.
    currency = transaction.money.currency
    own_share = Money(amount=body.own_share, currency=currency)
    try:
        validate_advance(transaction, own_share)
    except AdvanceError as exc:
        # ``exc.reason`` is a stable, value-free code (no financial data).
        raise HTTPException(status_code=422, detail=exc.reason) from exc

    advance = Advance(
        user_id=user_id,
        transaction_id=transaction.id,
        own_share=own_share,
        participants=[
            Participant(
                name=p.name,
                expected_amount=Money(amount=p.expected_amount, currency=currency),
            )
            for p in body.participants
        ],
    )
    created = create_advance(session, advance=advance)
    set_transaction_role(
        session, user_id=user_id, transaction_id=transaction.id, role=TransactionRole.ADVANCE
    )
    session.commit()

    logger.info("advances.create", advance_id=str(created.id))
    return AdvanceResponse.from_domain(created, transaction)


@router.get("/advances", response_model=AdvancesResponse)
def advances(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AdvancesResponse:
    """List the current user's advances, oldest first.

    Scoped to the current user. Each advance's receivable/outstanding is derived
    from its transaction.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose advances to return.

    Returns
    -------
    AdvancesResponse
        The user's advances, oldest first (empty if none).
    """
    found = list_advances(session, user_id)
    responses = [
        AdvanceResponse.from_domain(
            advance,
            _load_transaction(session, user_id=user_id, transaction_id=advance.transaction_id),
        )
        for advance in found
    ]
    logger.info("advances.list", count=len(responses))
    return AdvancesResponse(advances=responses)


@router.get("/advances/{advance_id}", response_model=AdvanceResponse)
def advance(
    advance_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AdvanceResponse:
    """Return one of the current user's advances.

    Scoped to the current user; a ``404`` if the advance is unknown or not the
    caller's.

    Parameters
    ----------
    advance_id : UUID
        The advance to fetch.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the advance belongs to.

    Returns
    -------
    AdvanceResponse
        The advance, with derived receivable/outstanding.
    """
    found = get_advance(session, user_id=user_id, advance_id=advance_id)
    if found is None:
        raise HTTPException(status_code=404, detail="unknown advance")
    transaction = _load_transaction(session, user_id=user_id, transaction_id=found.transaction_id)
    return AdvanceResponse.from_domain(found, transaction)


@router.delete("/advances/{advance_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_advance(
    advance_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete an advance and revert its transaction to ``personal``.

    The inverse of create: remove the advance (and its participants) and restore
    the transaction's role so its ``effective_amount`` returns to the full amount.
    Scoped to the current user; a ``404`` if the advance is unknown or not the
    caller's.

    Parameters
    ----------
    advance_id : UUID
        The advance to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the advance belongs to.
    """
    deleted = delete_advance(session, user_id=user_id, advance_id=advance_id)
    if deleted is None:
        raise HTTPException(status_code=404, detail="unknown advance")
    set_transaction_role(
        session,
        user_id=user_id,
        transaction_id=deleted.transaction_id,
        role=TransactionRole.PERSONAL,
    )
    session.commit()
    logger.info("advances.delete", advance_id=str(advance_id))
