"""Reimbursement endpoints: create/list/delete under an advance.

Reimbursements record money paid back against an advance — either a linked
incoming transaction (whose ``role`` becomes ``reimbursement``) or a manual cash
entry. The advance's ``outstanding``/``status`` are derived from their sum (see
:func:`~traccio.domain.advances.derive_advance` and ADR 0004). Automatic SEPA
matching is a separate later slice — nothing here suggests, every link is an
explicit user action.

Split out of :mod:`traccio.api.routers.advances` (2026-09-17): reimbursements
are their own resource, nested under ``/advances/{id}/reimbursements`` the same
way ``/events/{id}/transactions`` is a resource of its own on the events
router, not a second concern folded into it.

Data safety (``docs/engineering.md``): these handlers log only ids and
counts — never amounts or descriptions.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id, load_or_404
from traccio.api.schemas.reimbursements import (
    CreateReimbursementRequest,
    ReimbursementResponse,
    ReimbursementsResponse,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    create_reimbursement,
    delete_reimbursement,
    get_advance,
    get_transaction,
    list_reimbursements,
    set_transaction_role,
)
from traccio.db.session import get_session
from traccio.domain.advances import ReimbursementError, validate_reimbursement
from traccio.domain.enums import AdvanceStatus, TransactionRole
from traccio.domain.models import Advance, Reimbursement, Transaction
from traccio.domain.money import Money

logger = get_logger(__name__)

router = APIRouter()


def _load_advance(session: Session, *, user_id: UUID, advance_id: UUID) -> Advance:
    """Load an advance owned by the user, or raise ``404``."""
    return load_or_404(
        lambda: get_advance(session, user_id=user_id, advance_id=advance_id),
        detail="unknown advance",
    )


def _load_transaction(session: Session, *, user_id: UUID, transaction_id: UUID) -> Transaction:
    """Load a transaction owned by the user, or raise ``404``.

    Scoping is enforced by :func:`get_transaction`, so naming another user's (or
    an unknown) transaction is indistinguishable from "not found".
    """
    return load_or_404(
        lambda: get_transaction(session, user_id=user_id, transaction_id=transaction_id),
        detail="unknown transaction",
    )


@router.post(
    "/advances/{advance_id}/reimbursements",
    response_model=ReimbursementResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_reimbursement_endpoint(
    advance_id: UUID,
    body: CreateReimbursementRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> ReimbursementResponse:
    """Record a reimbursement against an advance.

    Two shapes: a manual **cash** entry (``transaction_id`` omitted) or a **link**
    to an existing incoming transaction, which then counts as neither income nor
    spending (its ``role`` becomes ``reimbursement``). The amount is a positive
    magnitude in the advance's currency and is otherwise free. Refused (``422``)
    on a ``written_off`` advance — reopen it first. Scoped to the current user.

    Parameters
    ----------
    advance_id : UUID
        The advance being paid back.
    body : CreateReimbursementRequest
        The amount, optional linked transaction, optional participant
        attribution, and optional note.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the advance belongs to.

    Returns
    -------
    ReimbursementResponse
        The created reimbursement.
    """
    advance = _load_advance(session, user_id=user_id, advance_id=advance_id)
    if advance.status is AdvanceStatus.WRITTEN_OFF:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="advance_written_off"
        )

    currency = advance.own_share.currency
    amount = Money(amount=body.amount, currency=currency)
    linked: Transaction | None = None
    if body.transaction_id is not None:
        linked = _load_transaction(session, user_id=user_id, transaction_id=body.transaction_id)

    # advance.participants is already in memory (loaded by _load_advance) — no
    # extra query, same treatment _load_transaction gives a 404.
    if body.participant_id is not None and not any(
        p.id == body.participant_id for p in advance.participants
    ):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown_participant")

    try:
        validate_reimbursement(amount, currency, transaction=linked)
    except ReimbursementError as exc:
        # ``exc.reason`` is a stable, value-free code (no financial data).
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=exc.reason
        ) from exc

    reimbursement = Reimbursement(
        user_id=user_id,
        advance_id=advance.id,
        amount=amount,
        transaction_id=body.transaction_id,
        participant_id=body.participant_id,
        note=body.note,
    )
    created = create_reimbursement(session, reimbursement=reimbursement)
    if linked is not None:
        set_transaction_role(
            session,
            user_id=user_id,
            transaction_id=linked.id,
            role=TransactionRole.REIMBURSEMENT,
        )
    session.commit()

    logger.info(
        "reimbursements.create", reimbursement_id=str(created.id), linked=linked is not None
    )
    return ReimbursementResponse.from_domain(created)


@router.get(
    "/advances/{advance_id}/reimbursements",
    response_model=ReimbursementsResponse,
)
def reimbursements(
    advance_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> ReimbursementsResponse:
    """List an advance's reimbursements, oldest first.

    Scoped to the current user; a ``404`` if the advance is unknown or not the
    caller's.

    Parameters
    ----------
    advance_id : UUID
        The advance whose reimbursements to list.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the advance belongs to.

    Returns
    -------
    ReimbursementsResponse
        The advance's reimbursements, oldest first (empty if none).
    """
    _load_advance(session, user_id=user_id, advance_id=advance_id)
    found = list_reimbursements(session, user_id=user_id, advance_id=advance_id)
    logger.info("reimbursements.list", count=len(found))
    return ReimbursementsResponse(
        reimbursements=[ReimbursementResponse.from_domain(r) for r in found]
    )


@router.delete(
    "/advances/{advance_id}/reimbursements/{reimbursement_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def remove_reimbursement(
    advance_id: UUID,
    reimbursement_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete a reimbursement; revert a linked transaction to ``personal``.

    The inverse of create: if the reimbursement linked a transaction, its ``role``
    returns to ``personal`` (so its ``effective_amount`` is restored). The
    advance's derived ``outstanding``/``status`` follow automatically. Scoped to
    the current user; a ``404`` if the reimbursement is unknown or not the
    caller's.

    Parameters
    ----------
    advance_id : UUID
        The advance the reimbursement belongs to.
    reimbursement_id : UUID
        The reimbursement to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the advance belongs to.
    """
    deleted = delete_reimbursement(
        session, user_id=user_id, advance_id=advance_id, reimbursement_id=reimbursement_id
    )
    if deleted is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown reimbursement")
    if deleted.transaction_id is not None:
        set_transaction_role(
            session,
            user_id=user_id,
            transaction_id=deleted.transaction_id,
            role=TransactionRole.PERSONAL,
        )
    session.commit()
    logger.info("reimbursements.delete", reimbursement_id=str(reimbursement_id))
