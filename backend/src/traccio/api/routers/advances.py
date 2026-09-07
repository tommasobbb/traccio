"""Advance endpoints: create/read/delete, reimbursements, and write-off.

An advance is an explicit user action on one outgoing transaction: it records the
user's declared ``own_share`` and sets the transaction's ``role`` to ``advance``,
so only that share counts as spending (via the one pure ``effective_amount``
function). Deleting an advance reverts the transaction to ``personal``.

Reimbursements record money paid back against an advance — either a linked
incoming transaction (whose ``role`` becomes ``reimbursement``) or a manual cash
entry. The advance's ``outstanding``/``status`` are derived from their sum (see
:func:`~traccio.domain.advances.derive_advance` and ADR 0004): ``settled`` is
derived, only ``written_off`` is stored. The write-off flow moves the outstanding
amount into the user's spending. Automatic SEPA matching is a separate later
slice — nothing here suggests, every link is an explicit user action.

Data safety (``.claude/rules/data-safety.md``): these handlers log only ids and
counts — never amounts or descriptions.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.advances import (
    AdvanceResponse,
    AdvancesResponse,
    AdvancesSummaryResponse,
    CreateAdvanceRequest,
)
from traccio.api.schemas.reimbursements import (
    CreateReimbursementRequest,
    ReimbursementResponse,
    ReimbursementsResponse,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    advance_exists_for_transaction,
    create_advance,
    create_reimbursement,
    delete_advance,
    delete_reimbursement,
    get_advance,
    get_transaction,
    list_advances,
    list_reimbursements,
    set_advance_status,
    set_transaction_role,
    sum_reimbursements_by_advance,
    sum_reimbursements_by_participant,
)
from traccio.db.session import get_session
from traccio.domain.advances import (
    AdvanceError,
    AdvanceState,
    ParticipantState,
    ReimbursementError,
    derive_advance,
    derive_participant_states,
    group_reimbursements_by_participant,
    summarize_people,
    total_receivable,
    validate_advance,
    validate_reimbursement,
)
from traccio.domain.enums import AdvanceStatus, TransactionRole
from traccio.domain.models import Advance, Participant, Reimbursement, Transaction
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


def _reimbursement_derivations(
    session: Session, *, user_id: UUID, advance: Advance
) -> tuple[Money, list[ParticipantState]]:
    """Derive an advance's reimbursed total and each participant's state.

    Loads the advance's reimbursements **once** and derives both from that
    same list — never two queries for one request, the exact discipline ADR
    0004 already requires for the total and ADR 0012 extends to the
    per-participant breakdown. A zero total and every participant
    ``outstanding`` when there are none.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advance; the query is scoped to it.
    advance : Advance
        The advance whose reimbursements to load and derive over.

    Returns
    -------
    tuple[Money, list[ParticipantState]]
        The reimbursed total, and each participant's derived state, in the
        same order as ``advance.participants``.
    """
    currency = advance.own_share.currency
    rows = list_reimbursements(session, user_id=user_id, advance_id=advance.id)
    reimbursed = Money(amount=sum(r.amount.amount for r in rows), currency=currency)
    participant_states = derive_participant_states(
        advance.participants,
        group_reimbursements_by_participant(rows),
        currency=currency,
    )
    return reimbursed, participant_states


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
    # No reimbursements exist yet — every participant comes back `outstanding`
    # from an empty map, the same derivation a real reimbursement later feeds.
    participant_states = derive_participant_states(created.participants, {}, currency=currency)
    return AdvanceResponse.from_domain(created, transaction, participant_states=participant_states)


@router.get("/advances", response_model=AdvancesResponse)
def advances(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    status: Annotated[AdvanceStatus | None, Query()] = None,
) -> AdvancesResponse:
    """List the current user's advances, oldest first, with cross-advance totals.

    Scoped to the current user. Each advance's receivable/outstanding is derived
    from its transaction; the ``summary`` rolls every advance up by person and
    by currency (ADR 0026).

    The optional ``status`` query parameter narrows the returned ``advances`` to
    one lifecycle state. It is applied **after** deriving every advance, because
    ``open``/``settled`` are derived and only ``written_off`` is stored — and
    the ``summary`` is always computed over the full set, so the totals do not
    move when the caller filters the rows.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose advances to return.
    status : AdvanceStatus or None
        When given, only advances whose derived status matches are returned in
        ``advances`` (the ``summary`` is unaffected).

    Returns
    -------
    AdvancesResponse
        The user's advances (oldest first, optionally filtered) and the
        cross-advance summary.
    """
    found = list_advances(session, user_id)
    # Both aggregates are one query for the whole page, never one per advance
    # or one per participant (ADR 0004 / ADR 0012).
    reimbursed_by_advance = sum_reimbursements_by_advance(session, user_id)
    reimbursed_by_participant = sum_reimbursements_by_participant(session, user_id)

    advance_states: list[AdvanceState] = []
    participant_states_by_advance: list[list[ParticipantState]] = []
    responses: list[AdvanceResponse] = []
    for advance in found:
        transaction = _load_transaction(
            session, user_id=user_id, transaction_id=advance.transaction_id
        )
        currency = advance.own_share.currency
        reimbursed = reimbursed_by_advance.get(advance.id, Money(amount=0, currency=currency))
        state = derive_advance(
            transaction,
            advance.own_share,
            reimbursed,
            written_off=advance.status is AdvanceStatus.WRITTEN_OFF,
        )
        participant_states = derive_participant_states(
            advance.participants, reimbursed_by_participant, currency=currency
        )
        advance_states.append(state)
        participant_states_by_advance.append(participant_states)
        if status is None or state.status is status:
            responses.append(
                AdvanceResponse.from_domain(
                    advance,
                    transaction,
                    reimbursed,
                    participant_states=participant_states,
                    state=state,
                )
            )

    summary = AdvancesSummaryResponse.from_domain(
        by_person=summarize_people(participant_states_by_advance),
        totals=total_receivable(advance_states),
    )
    logger.info("advances.list", count=len(responses), total=len(found))
    return AdvancesResponse(advances=responses, summary=summary)


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
    reimbursed, participant_states = _reimbursement_derivations(
        session, user_id=user_id, advance=found
    )
    return AdvanceResponse.from_domain(
        found, transaction, reimbursed, participant_states=participant_states
    )


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


def _load_advance(session: Session, *, user_id: UUID, advance_id: UUID) -> Advance:
    """Load an advance owned by the user, or raise ``404``."""
    advance = get_advance(session, user_id=user_id, advance_id=advance_id)
    if advance is None:
        raise HTTPException(status_code=404, detail="unknown advance")
    return advance


def _advance_response(session: Session, *, user_id: UUID, advance: Advance) -> AdvanceResponse:
    """Project an advance with its transaction, reimbursed total, and
    per-participant states threaded in."""
    transaction = _load_transaction(session, user_id=user_id, transaction_id=advance.transaction_id)
    reimbursed, participant_states = _reimbursement_derivations(
        session, user_id=user_id, advance=advance
    )
    return AdvanceResponse.from_domain(
        advance, transaction, reimbursed, participant_states=participant_states
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
        raise HTTPException(status_code=422, detail="advance_written_off")

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
        raise HTTPException(status_code=404, detail="unknown_participant")

    try:
        validate_reimbursement(amount, currency, transaction=linked)
    except ReimbursementError as exc:
        # ``exc.reason`` is a stable, value-free code (no financial data).
        raise HTTPException(status_code=422, detail=exc.reason) from exc

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
        raise HTTPException(status_code=404, detail="unknown reimbursement")
    if deleted.transaction_id is not None:
        set_transaction_role(
            session,
            user_id=user_id,
            transaction_id=deleted.transaction_id,
            role=TransactionRole.PERSONAL,
        )
    session.commit()
    logger.info("reimbursements.delete", reimbursement_id=str(reimbursement_id))


@router.post("/advances/{advance_id}/write-off", response_model=AdvanceResponse)
def write_off_advance(
    advance_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AdvanceResponse:
    """Write off an advance the user gave up on collecting.

    Moves the outstanding amount into the user's spending: the transaction's
    ``effective_amount`` grows from ``own_share`` to ``own_share + outstanding``
    (see :func:`~traccio.domain.advances.derive_advance`). Refused (``422``) when
    there is nothing outstanding to write off. Scoped to the current user; a
    ``404`` if the advance is unknown or not the caller's.

    Parameters
    ----------
    advance_id : UUID
        The advance to write off.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the advance belongs to.

    Returns
    -------
    AdvanceResponse
        The advance in its ``written_off`` state.
    """
    advance = _load_advance(session, user_id=user_id, advance_id=advance_id)
    transaction = _load_transaction(session, user_id=user_id, transaction_id=advance.transaction_id)
    reimbursed, _participant_states = _reimbursement_derivations(
        session, user_id=user_id, advance=advance
    )
    state = derive_advance(transaction, advance.own_share, reimbursed, written_off=False)
    if state.outstanding.amount <= 0:
        raise HTTPException(status_code=422, detail="nothing_outstanding")

    set_advance_status(
        session, user_id=user_id, advance_id=advance.id, status=AdvanceStatus.WRITTEN_OFF
    )
    session.commit()
    logger.info("advances.write_off", advance_id=str(advance_id))

    updated = _load_advance(session, user_id=user_id, advance_id=advance_id)
    return _advance_response(session, user_id=user_id, advance=updated)


@router.post("/advances/{advance_id}/reopen", response_model=AdvanceResponse)
def reopen_advance(
    advance_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AdvanceResponse:
    """Reverse a write-off, returning the advance to an open lifecycle.

    Sets the stored status back to ``open``; the derived status then follows the
    reimbursements again (``settled`` if they cover the receivable, else
    ``open``). The transaction's ``effective_amount`` returns to ``own_share``.
    Scoped to the current user; a ``404`` if the advance is unknown or not the
    caller's.

    Parameters
    ----------
    advance_id : UUID
        The advance to reopen.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the advance belongs to.

    Returns
    -------
    AdvanceResponse
        The advance with its derived, no-longer-written-off state.
    """
    _load_advance(session, user_id=user_id, advance_id=advance_id)
    set_advance_status(session, user_id=user_id, advance_id=advance_id, status=AdvanceStatus.OPEN)
    session.commit()
    logger.info("advances.reopen", advance_id=str(advance_id))

    updated = _load_advance(session, user_id=user_id, advance_id=advance_id)
    return _advance_response(session, user_id=user_id, advance=updated)
