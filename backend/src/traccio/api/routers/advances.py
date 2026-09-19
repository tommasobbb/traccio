"""Advance endpoints: create/read/delete and write-off.

An advance is an explicit user action on one outgoing transaction: it records the
user's declared ``own_share`` and sets the transaction's ``role`` to ``advance``,
so only that share counts as spending (via the one pure ``effective_amount``
function). Deleting an advance reverts the transaction to ``personal``.

The advance's ``outstanding``/``status`` are derived from the sum of its
reimbursements (see :func:`~traccio.domain.advances.derive_advance` and ADR
0004): ``settled`` is derived, only ``written_off`` is stored. The write-off
flow moves the outstanding amount into the user's spending. Reimbursements
themselves — recording money paid back — are a resource of their own, on the
same ``/advances/{id}/reimbursements`` path prefix but in
:mod:`traccio.api.routers.reimbursements`, the same split ``/events/{id}/...``
already has between this package's routers.

Data safety (``docs/engineering.md``): these handlers log only ids and
counts — never amounts or descriptions.
"""

from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_tracking_start, current_user_id, load_or_404
from traccio.api.schemas.advances import (
    AdvanceResponse,
    AdvancesResponse,
    AdvancesSummaryResponse,
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
    list_reimbursements,
    list_transactions_by_ids,
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
    derive_advance,
    derive_participant_states,
    group_reimbursements_by_participant,
    summarize_people,
    total_receivable,
    validate_advance,
)
from traccio.domain.enums import AdvanceStatus, TransactionRole
from traccio.domain.models import Advance, Participant, Transaction
from traccio.domain.money import Money
from traccio.domain.tracking import is_within_tracking

logger = get_logger(__name__)

router = APIRouter()


def _load_transaction(session: Session, *, user_id: UUID, transaction_id: UUID) -> Transaction:
    """Load a transaction owned by the user, or raise ``404``.

    Scoping is enforced by :func:`get_transaction`, so naming another user's (or
    an unknown) transaction is indistinguishable from "not found".
    """
    return load_or_404(
        lambda: get_transaction(session, user_id=user_id, transaction_id=transaction_id),
        detail="unknown transaction",
    )


def _load_advance(session: Session, *, user_id: UUID, advance_id: UUID) -> Advance:
    """Load an advance owned by the user, or raise ``404``."""
    return load_or_404(
        lambda: get_advance(session, user_id=user_id, advance_id=advance_id),
        detail="unknown advance",
    )


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
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="transaction already has an advance"
        )

    # own_share and participant amounts are always in the transaction's currency.
    currency = transaction.money.currency
    own_share = Money(amount=body.own_share, currency=currency)
    try:
        validate_advance(transaction, own_share)
    except AdvanceError as exc:
        # ``exc.reason`` is a stable, value-free code (no financial data).
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=exc.reason
        ) from exc

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
    tracking_start: Annotated[date | None, Depends(current_tracking_start)] = None,
    status: Annotated[AdvanceStatus | None, Query()] = None,
) -> AdvancesResponse:
    """List the current user's advances, oldest first, with cross-advance totals.

    Scoped to the current user. Each advance's receivable/outstanding is derived
    from its transaction; the ``summary`` rolls every advance up by person and
    by currency (ADR 0026).

    An advance whose transaction falls **before** the user's tracking-start
    floor (ADR 0024) is omitted entirely — from ``advances`` and from
    ``summary`` alike — so "chi ti deve" and "da ricevere" count the same
    movements the dashboard and Movimenti do. The floor is skipped when unset,
    and by-id reads (``GET /advances/{id}``) still see every advance: an
    explicit link to an old movement keeps working (ADR 0024 §5).

    The optional ``status`` query parameter narrows the returned ``advances`` to
    one lifecycle state. It is applied **after** deriving every advance, because
    ``open``/``settled`` are derived and only ``written_off`` is stored — and
    the ``summary`` is always computed over the full (in-window) set, so the
    totals do not move when the caller filters the rows.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose advances to return.
    tracking_start : date or None
        The user's tracking-start floor; advances on a movement before it are
        excluded. ``None`` means no floor.
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
    # All three are one query for the whole page, never one per advance or
    # one per participant (ADR 0004 / ADR 0012) — including the linked
    # transactions, batched here rather than one _load_transaction per advance.
    reimbursed_by_advance = sum_reimbursements_by_advance(session, user_id)
    reimbursed_by_participant = sum_reimbursements_by_participant(session, user_id)
    transactions_by_id = list_transactions_by_ids(
        session, user_id=user_id, ids=[advance.transaction_id for advance in found]
    )

    advance_states: list[AdvanceState] = []
    participant_states_by_advance: list[list[ParticipantState]] = []
    responses: list[AdvanceResponse] = []
    for advance in found:
        transaction = transactions_by_id.get(advance.transaction_id)
        if transaction is None:
            # status_code=404, spelled as a literal: `status` in this
            # function's scope is the AdvanceStatus query parameter above,
            # shadowing the fastapi.status module every other 404 in this
            # file uses.
            raise HTTPException(status_code=404, detail="unknown transaction")
        # Applied here, where the transaction is already in hand: skipping the
        # advance before it reaches ``advance_states`` /
        # ``participant_states_by_advance`` keeps the rows and the summary in
        # lockstep (ADR 0024 / ADR 0026).
        if not is_within_tracking(transaction, tracking_start):
            continue
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
    logger.info(
        "advances.list",
        count=len(responses),
        in_window=len(advance_states),
        total=len(found),
    )
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
    found = _load_advance(session, user_id=user_id, advance_id=advance_id)
    return _advance_response(session, user_id=user_id, advance=found)


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
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown advance")
    set_transaction_role(
        session,
        user_id=user_id,
        transaction_id=deleted.transaction_id,
        role=TransactionRole.PERSONAL,
    )
    session.commit()
    logger.info("advances.delete", advance_id=str(advance_id))


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
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="nothing_outstanding"
        )

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
