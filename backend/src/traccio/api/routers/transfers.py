"""Transfer endpoints: suggest (read-only), confirm, reject, and manage.

Detection only *suggests* (``GET /transfers/suggestions``); it never links (see
``docs/architecture.md``). Turning a suggestion into a persisted
:class:`~traccio.domain.models.Transfer` is an explicit user action:

- ``POST /transfers/confirm`` links two legs and sets both to ``role=transfer``
  (which zeroes their ``effective_amount`` via the one pure domain function).
- ``POST /transfers/reject`` records a dismissal so the pair is not suggested
  again.
- ``DELETE /transfers/{id}`` unlinks and reverts both legs to ``personal``.
- ``GET /transfers`` lists the confirmed transfers.

Data safety (``.claude/rules/data-safety.md``): these handlers log only ids and
counts — never amounts or descriptions.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.transfers import (
    ConfirmTransferRequest,
    RejectTransferRequest,
    TransferResponse,
    TransfersResponse,
    TransferSuggestionResponse,
    TransferSuggestionsResponse,
)
from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    create_transfer,
    create_transfer_dismissal,
    delete_transfer,
    get_transaction,
    list_all_transactions,
    list_transfer_dismissals,
    list_transfers,
    set_transaction_role,
    transfer_exists_for_transaction,
)
from traccio.db.session import get_session
from traccio.domain.enums import TransactionRole
from traccio.domain.models import Transaction, Transfer
from traccio.services.transfers import (
    TransferPairError,
    detect_transfers,
    validate_transfer_pair,
)

logger = get_logger(__name__)

router = APIRouter()


def _load_leg(session: Session, *, user_id: UUID, transaction_id: UUID) -> Transaction:
    """Load a transaction owned by the user, or raise ``404``.

    Scoping is enforced by :func:`get_transaction`, so naming another user's (or
    an unknown) transaction is indistinguishable from "not found".
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="unknown transaction")
    return transaction


@router.get("/transfers/suggestions", response_model=TransferSuggestionsResponse)
def transfer_suggestions(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransferSuggestionsResponse:
    """Suggest transfers among the current user's transactions.

    Computed on demand and **read-only**: detection only proposes pairs, it never
    links them (``docs/architecture.md``). Pairs the user has rejected are
    excluded via stored dismissals, so a rejected suggestion does not reappear.
    Scoped to the current user; the tolerance and window come from settings.

    Parameters
    ----------
    session : Session
        Request-scoped database session (see :func:`get_session`).
    user_id : UUID
        The user whose transactions to search.

    Returns
    -------
    TransferSuggestionsResponse
        The suggested transfers, most confident first (empty if none).
    """
    settings = get_settings()
    transactions = list_all_transactions(session, user_id)
    dismissed = list_transfer_dismissals(session, user_id)
    suggestions = detect_transfers(
        transactions,
        amount_tolerance_cents=settings.transfer_amount_tolerance_cents,
        window_days=settings.transfer_window_days,
        dismissed_pairs=dismissed,
    )
    # Log a count, never transaction contents (see data-safety rules).
    logger.info("transfers.suggestions", count=len(suggestions))
    return TransferSuggestionsResponse(
        suggestions=[TransferSuggestionResponse.from_domain(s) for s in suggestions]
    )


@router.post(
    "/transfers/confirm",
    response_model=TransferResponse,
    status_code=status.HTTP_201_CREATED,
)
def confirm_transfer(
    body: ConfirmTransferRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransferResponse:
    """Confirm two transactions as a transfer.

    The explicit user action that turns a suggestion into a persisted link: it
    validates the pair (same invariants detection uses, minus the tolerance and
    window — a user may link any structurally valid pair), records the
    :class:`~traccio.domain.models.Transfer`, and sets both legs' ``role`` to
    ``transfer`` so their ``effective_amount`` becomes zero. Scoped to the
    current user.

    Parameters
    ----------
    body : ConfirmTransferRequest
        The outgoing (negative) and incoming (positive) legs to link.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transactions belong to.

    Returns
    -------
    TransferResponse
        The created transfer.
    """
    outgoing = _load_leg(session, user_id=user_id, transaction_id=body.outgoing_transaction_id)
    incoming = _load_leg(session, user_id=user_id, transaction_id=body.incoming_transaction_id)

    # A transaction belongs to at most one transfer.
    for leg in (outgoing, incoming):
        if transfer_exists_for_transaction(session, user_id=user_id, transaction_id=leg.id):
            raise HTTPException(status_code=409, detail="transaction already in a transfer")

    try:
        validate_transfer_pair(outgoing, incoming)
    except TransferPairError as exc:
        # ``exc.reason`` is a stable, value-free code (no financial data).
        raise HTTPException(status_code=422, detail=exc.reason) from exc

    transfer = Transfer(
        user_id=user_id,
        outgoing_transaction_id=outgoing.id,
        incoming_transaction_id=incoming.id,
    )
    created = create_transfer(session, transfer=transfer)
    for leg in (outgoing, incoming):
        set_transaction_role(
            session, user_id=user_id, transaction_id=leg.id, role=TransactionRole.TRANSFER
        )
    session.commit()

    logger.info("transfers.confirm", transfer_id=str(created.id))
    return TransferResponse.from_domain(created)


@router.post("/transfers/reject", status_code=status.HTTP_204_NO_CONTENT)
def reject_transfer(
    body: RejectTransferRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Reject a suggested pair so it is not suggested again.

    Records an order-independent dismissal for the two legs. Idempotent: rejecting
    the same pair twice changes nothing. Both legs must belong to the caller.
    Scoped to the current user.

    Parameters
    ----------
    body : RejectTransferRequest
        The two legs of the rejected suggestion.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transactions belong to.
    """
    outgoing = _load_leg(session, user_id=user_id, transaction_id=body.outgoing_transaction_id)
    incoming = _load_leg(session, user_id=user_id, transaction_id=body.incoming_transaction_id)
    create_transfer_dismissal(
        session,
        user_id=user_id,
        transaction_id_a=outgoing.id,
        transaction_id_b=incoming.id,
    )
    session.commit()
    logger.info("transfers.reject")


@router.delete("/transfers/{transfer_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_transfer(
    transfer_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete a confirmed transfer and revert both legs to ``personal``.

    The inverse of confirm: unlink the two transactions and restore their role so
    their ``effective_amount`` returns to the full amount. Scoped to the current
    user; a ``404`` if the transfer is unknown or not the caller's.

    Parameters
    ----------
    transfer_id : UUID
        The transfer to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transfer belongs to.
    """
    transfer = delete_transfer(session, user_id=user_id, transfer_id=transfer_id)
    if transfer is None:
        raise HTTPException(status_code=404, detail="unknown transfer")
    for transaction_id in (transfer.outgoing_transaction_id, transfer.incoming_transaction_id):
        set_transaction_role(
            session, user_id=user_id, transaction_id=transaction_id, role=TransactionRole.PERSONAL
        )
    session.commit()
    logger.info("transfers.delete", transfer_id=str(transfer_id))


@router.get("/transfers", response_model=TransfersResponse)
def transfers(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransfersResponse:
    """List the current user's confirmed transfers, oldest first.

    Scoped to the current user.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose transfers to return.

    Returns
    -------
    TransfersResponse
        The user's confirmed transfers, oldest first (empty if none).
    """
    found = list_transfers(session, user_id)
    logger.info("transfers.list", count=len(found))
    return TransfersResponse(transfers=[TransferResponse.from_domain(t) for t in found])
