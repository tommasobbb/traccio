"""Event endpoints: CRUD, transaction membership, and the derived total.

An event groups transactions from one real-world occasion (a trip, a
renovation) so the user can see what it actually cost — the sum of its members'
``effective_amount``, so a transfer between own accounts counts zero, an advance
only the user's share, a reimbursement zero (see ``docs/domain.md`` §Event).

An event is a **reporting lens, not a role**: assigning a transaction sets its
``event_id`` and never touches its ``role`` or ``effective_amount``. A
transaction belongs to at most one event; assigning one already grouped
elsewhere is refused (``409``). Deleting an event removes only the grouping — the
transactions survive, back to no event.

Data safety (``.claude/rules/data-safety.md``): these handlers log only ids and
counts — never amounts, descriptions, or names.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.dashboard import CategoryDisplay
from traccio.api.schemas.events import (
    AssignTransactionRequest,
    CreateEventRequest,
    EventResponse,
    EventsResponse,
    EventSummaryResponse,
    UpdateEventRequest,
)
from traccio.api.schemas.transactions import TransactionResponse, TransactionsResponse
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    assign_transaction_to_event,
    create_event,
    delete_event,
    get_event,
    get_transaction,
    get_transaction_event_id,
    list_advances,
    list_categories,
    list_event_candidates,
    list_event_members,
    list_events,
    set_event_status,
    sum_reimbursements_by_advance,
    unassign_transaction_from_event,
    update_event,
)
from traccio.db.session import get_session
from traccio.domain.dashboard import summarize
from traccio.domain.enums import EventStatus
from traccio.domain.events import event_total
from traccio.domain.models import Advance, Event, Transaction
from traccio.domain.money import Money
from traccio.services.advances import spending_shares

logger = get_logger(__name__)

router = APIRouter()


def _load_event(session: Session, *, user_id: UUID, event_id: UUID) -> Event:
    """Load an event owned by the user, or raise ``404``.

    Scoping is enforced by :func:`get_event`, so naming another user's (or an
    unknown) event is indistinguishable from "not found".
    """
    event = get_event(session, user_id=user_id, event_id=event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="unknown event")
    return event


def _advance_spending_shares(
    session: Session,
    *,
    user_id: UUID,
    transactions: list[Transaction],
    advance_by_tx: dict[UUID, Advance] | None = None,
    reimbursed: dict[UUID, Money] | None = None,
) -> dict[UUID, Money]:
    """Resolve each advanced transaction's signed spending share.

    Shared by :func:`_event_response` (the derived net total) and
    :func:`event_transactions` (the member listing) — both need the same
    advance-share resolution :func:`~traccio.api.routers.transactions.transactions`
    performs, since an advance's ``effective_amount`` is a derived share, not its
    full amount.

    ``advance_by_tx``/``reimbursed`` let a caller that already listed the
    user's whole advance pool (:func:`events`, over every event in one page)
    pass it in once instead of this function re-fetching the identical
    user-wide result set on every call.
    """
    if advance_by_tx is None:
        advance_by_tx = {
            advance.transaction_id: advance for advance in list_advances(session, user_id)
        }
    if reimbursed is None:
        reimbursed = sum_reimbursements_by_advance(session, user_id)
    return spending_shares(transactions, advance_by_tx=advance_by_tx, reimbursed=reimbursed)


def _event_response(
    session: Session,
    *,
    user_id: UUID,
    event: Event,
    advance_by_tx: dict[UUID, Advance] | None = None,
    reimbursed: dict[UUID, Money] | None = None,
) -> EventResponse:
    """Project an event with its derived net total and member count threaded in.

    Resolves each advance member's spending share (via
    :func:`_advance_spending_shares`) so the pure
    :func:`~traccio.domain.events.event_total` can sum ``effective_amount`` across
    the members in the event's single currency. ``advance_by_tx``/``reimbursed``
    are forwarded to :func:`_advance_spending_shares` unchanged — see there.
    """
    members = list_event_members(session, user_id=user_id, event_id=event.id)
    shares = _advance_spending_shares(
        session,
        user_id=user_id,
        transactions=members,
        advance_by_tx=advance_by_tx,
        reimbursed=reimbursed,
    )
    total = event_total(members, advance_shares=shares)
    return EventResponse.from_domain(event, total=total, member_count=len(members))


@router.post("/events", response_model=EventResponse, status_code=status.HTTP_201_CREATED)
def create_event_endpoint(
    body: CreateEventRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> EventResponse:
    """Create an event.

    Records the occasion's name and optional date range; it starts ``active``
    with no members and a zero total. Scoped to the current user.

    Parameters
    ----------
    body : CreateEventRequest
        The event's name and optional start/end dates.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    EventResponse
        The created event, with an empty total.
    """
    event = Event(
        user_id=user_id,
        name=body.name,
        emoji=body.emoji,
        color=body.color,
        start_date=body.start_date,
        end_date=body.end_date,
    )
    created = create_event(session, event=event)
    session.commit()
    logger.info("events.create", event_id=str(created.id))
    return _event_response(session, user_id=user_id, event=created)


@router.post("/events/{event_id}", response_model=EventResponse)
def update_event_endpoint(
    event_id: UUID,
    body: UpdateEventRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> EventResponse:
    """Edit an event's name, emoji, colour and date range (ADR 0027).

    A full replace of the fields the client's single event editor owns; the
    event's ``status`` and membership are untouched. ``emoji`` is validated as
    a single emoji by the request schema (a ``422`` otherwise). Scoped to the
    current user; a ``404`` if the event is unknown or not the caller's.

    Parameters
    ----------
    event_id : UUID
        The event to edit.
    body : UpdateEventRequest
        The new name, emoji, colour and dates (each ``null`` clears).
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    EventResponse
        The updated event, with its derived total and member count.
    """
    updated = update_event(
        session,
        user_id=user_id,
        event_id=event_id,
        name=body.name,
        emoji=body.emoji,
        color=body.color,
        start_date=body.start_date,
        end_date=body.end_date,
    )
    if updated is None:
        raise HTTPException(status_code=404, detail="unknown event")
    session.commit()
    logger.info("events.update", event_id=str(updated.id))
    return _event_response(session, user_id=user_id, event=updated)


@router.get("/events", response_model=EventsResponse)
def events(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> EventsResponse:
    """List the current user's events, oldest first.

    Scoped to the current user. Each event carries its derived net total and
    member count.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose events to return.

    Returns
    -------
    EventsResponse
        The user's events, oldest first (empty if none).
    """
    found = list_events(session, user_id)
    # Fetched once for the whole page, not once per event: every event needs
    # the same user-wide advance pool and reimbursement totals to resolve its
    # members' spending shares, so re-fetching per event would be 2 queries
    # times the event count for identical data every time.
    advance_by_tx = {advance.transaction_id: advance for advance in list_advances(session, user_id)}
    reimbursed = sum_reimbursements_by_advance(session, user_id)
    responses = [
        _event_response(
            session,
            user_id=user_id,
            event=event,
            advance_by_tx=advance_by_tx,
            reimbursed=reimbursed,
        )
        for event in found
    ]
    logger.info("events.list", count=len(responses))
    return EventsResponse(events=responses)


@router.get("/events/{event_id}", response_model=EventResponse)
def event(
    event_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> EventResponse:
    """Return one of the current user's events, with its derived total.

    Scoped to the current user; a ``404`` if the event is unknown or not the
    caller's.

    Parameters
    ----------
    event_id : UUID
        The event to fetch.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    EventResponse
        The event, with its net total and member count.
    """
    found = _load_event(session, user_id=user_id, event_id=event_id)
    return _event_response(session, user_id=user_id, event=found)


@router.get("/events/{event_id}/transactions", response_model=TransactionsResponse)
def event_transactions(
    event_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransactionsResponse:
    """List an event's member transactions, most recent first.

    Membership is a reporting lens (see the module docstring): this endpoint
    only reads which transactions are grouped under the event, unpaginated —
    an event's members are a bounded set, unlike ``GET /transactions``'s
    unbounded pool. Scoped to the current user; a ``404`` if the event is
    unknown or not the caller's.

    Parameters
    ----------
    event_id : UUID
        The event whose members to list.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    TransactionsResponse
        The event's member transactions, most recent first (empty if none).
    """
    _load_event(session, user_id=user_id, event_id=event_id)
    members = list_event_members(session, user_id=user_id, event_id=event_id)
    shares = _advance_spending_shares(session, user_id=user_id, transactions=members)
    responses = [
        TransactionResponse.from_domain(
            transaction, advance_own_share=shares.get(transaction.id), event_id=event_id
        )
        for transaction in members
    ]
    logger.info("events.transactions.list", event_id=str(event_id), count=len(responses))
    return TransactionsResponse(transactions=responses)


@router.get("/events/{event_id}/suggestions", response_model=TransactionsResponse)
def event_suggestions(
    event_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransactionsResponse:
    """Suggest un-grouped transactions dated within the event's range.

    The date range is a *hint*, never a rule (``docs/domain.md`` §Event), so
    this only *suggests* — the client still assigns each one with an explicit
    ``POST``, the same posture as transfer and reimbursement matching. Returns
    un-grouped (``event_id IS NULL``) transactions whose
    ``coalesce(booked_at, value_date)`` falls within ``[start_date, end_date]``,
    most recent first. An event without **both** bounds set yields an empty
    list — there is no window to suggest from. Scoped to the current user; a
    ``404`` if the event is unknown or not the caller's.

    Parameters
    ----------
    event_id : UUID
        The event whose date range drives the suggestion.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    TransactionsResponse
        Candidate transactions (empty when the event has no full date range).
    """
    event = _load_event(session, user_id=user_id, event_id=event_id)
    if event.start_date is None or event.end_date is None:
        return TransactionsResponse(transactions=[])
    candidates = list_event_candidates(
        session, user_id=user_id, start=event.start_date, end=event.end_date
    )
    responses = [TransactionResponse.from_domain(transaction) for transaction in candidates]
    logger.info("events.suggestions", event_id=str(event_id), count=len(responses))
    return TransactionsResponse(transactions=responses)


@router.get("/events/{event_id}/summary", response_model=EventSummaryResponse)
def event_summary(
    event_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> EventSummaryResponse:
    """Return an event's spending broken down by category (ADR 0028).

    Reuses the dashboard's :func:`~traccio.domain.dashboard.summarize` over the
    event's members — the same two-level ``by_category`` (ADR 0018) the
    dashboard returns for a period, so the client renders it with the same
    donut and breakdown list. An event is single-currency by construction, so
    there is exactly one currency summary; an empty event yields zeros and
    ``currency: null``. Scoped to the current user; a ``404`` if the event is
    unknown or not the caller's.

    Parameters
    ----------
    event_id : UUID
        The event whose breakdown to compute.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    EventSummaryResponse
        The members' spending/income and their per-category partition.
    """
    _load_event(session, user_id=user_id, event_id=event_id)
    members = list_event_members(session, user_id=user_id, event_id=event_id)
    shares = _advance_spending_shares(session, user_id=user_id, transactions=members)

    categories = list_categories(session, user_id)
    parents = {category.id: category.parent_id for category in categories}
    display = {
        category.id: CategoryDisplay(
            name=category.name, color=category.color, icon=category.icon
        )
        for category in categories
    }

    summaries = summarize(members, advance_shares=shares, parents=parents)
    # One currency by construction (a mixed-currency member is refused on
    # assign); an empty event produces no summary at all.
    summary = summaries[0] if summaries else None
    category_count = 0 if summary is None else len(summary.by_category)
    logger.info("events.summary", event_id=str(event_id), categories=category_count)
    return EventSummaryResponse.from_currency_summary(summary, display=display)


@router.delete("/events/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_event(
    event_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete an event, keeping its member transactions.

    Removes only the grouping: every member's ``event_id`` is cleared and the
    transactions themselves are untouched (see ``docs/domain.md``). Scoped to the
    current user; a ``404`` if the event is unknown or not the caller's.

    Parameters
    ----------
    event_id : UUID
        The event to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.
    """
    deleted = delete_event(session, user_id=user_id, event_id=event_id)
    if deleted is None:
        raise HTTPException(status_code=404, detail="unknown event")
    session.commit()
    logger.info("events.delete", event_id=str(event_id))


@router.post("/events/{event_id}/transactions", status_code=status.HTTP_204_NO_CONTENT)
def assign_transaction(
    event_id: UUID,
    body: AssignTransactionRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Group a transaction under an event.

    Sets the transaction's ``event_id`` — the membership is a reporting lens and
    does not change its ``role`` or ``effective_amount``. A ``404`` if the event
    or transaction is unknown or not the caller's; a ``409`` if the transaction
    already belongs to a *different* event (one event per transaction).
    Re-assigning to the same event is idempotent. Scoped to the current user.

    Parameters
    ----------
    event_id : UUID
        The event to group the transaction under.
    body : AssignTransactionRequest
        The transaction to assign.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user both the event and transaction belong to.
    """
    _load_event(session, user_id=user_id, event_id=event_id)
    transaction = get_transaction(session, user_id=user_id, transaction_id=body.transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="unknown transaction")

    current = get_transaction_event_id(session, user_id=user_id, transaction_id=transaction.id)
    if current is not None and current != event_id:
        raise HTTPException(status_code=409, detail="transaction already in another event")

    # Keep every event single-currency: its total is a sum of amounts in one
    # currency (no FX in Traccio). Every member shares the transaction's currency,
    # so comparing against any existing member is enough.
    members = list_event_members(session, user_id=user_id, event_id=event_id)
    if members and members[0].money.currency != transaction.money.currency:
        raise HTTPException(status_code=422, detail="mixed_currency")

    assign_transaction_to_event(
        session, user_id=user_id, event_id=event_id, transaction_id=transaction.id
    )
    session.commit()
    logger.info("events.assign", event_id=str(event_id))


@router.delete(
    "/events/{event_id}/transactions/{transaction_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def unassign_transaction(
    event_id: UUID,
    transaction_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Remove a transaction from an event, keeping the transaction.

    Clears the transaction's ``event_id``. A ``404`` if the event is unknown, or
    if the transaction is unknown or not currently a member of *this* event.
    Scoped to the current user.

    Parameters
    ----------
    event_id : UUID
        The event to remove the transaction from.
    transaction_id : UUID
        The transaction to unassign.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user both the event and transaction belong to.
    """
    _load_event(session, user_id=user_id, event_id=event_id)
    current = get_transaction_event_id(session, user_id=user_id, transaction_id=transaction_id)
    if current != event_id:
        # Either the transaction is unknown/not the caller's (current is None) or
        # it belongs to a different event — in every case it is not a member here.
        raise HTTPException(status_code=404, detail="transaction not in event")

    unassign_transaction_from_event(
        session, user_id=user_id, event_id=event_id, transaction_id=transaction_id
    )
    session.commit()
    logger.info("events.unassign", event_id=str(event_id))


@router.post("/events/{event_id}/close", response_model=EventResponse)
def close_event(
    event_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> EventResponse:
    """Mark an event ``closed``.

    Purely organizational — a closed event still reports its total and can be
    reopened; nothing about its members changes. Scoped to the current user; a
    ``404`` if the event is unknown or not the caller's.

    Parameters
    ----------
    event_id : UUID
        The event to close.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    EventResponse
        The event in its ``closed`` state.
    """
    _load_event(session, user_id=user_id, event_id=event_id)
    set_event_status(session, user_id=user_id, event_id=event_id, status=EventStatus.CLOSED)
    session.commit()
    logger.info("events.close", event_id=str(event_id))
    updated = _load_event(session, user_id=user_id, event_id=event_id)
    return _event_response(session, user_id=user_id, event=updated)


@router.post("/events/{event_id}/reopen", response_model=EventResponse)
def reopen_event(
    event_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> EventResponse:
    """Reopen a closed event, marking it ``active`` again.

    Scoped to the current user; a ``404`` if the event is unknown or not the
    caller's.

    Parameters
    ----------
    event_id : UUID
        The event to reopen.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the event belongs to.

    Returns
    -------
    EventResponse
        The event in its ``active`` state.
    """
    _load_event(session, user_id=user_id, event_id=event_id)
    set_event_status(session, user_id=user_id, event_id=event_id, status=EventStatus.ACTIVE)
    session.commit()
    logger.info("events.reopen", event_id=str(event_id))
    updated = _load_event(session, user_id=user_id, event_id=event_id)
    return _event_response(session, user_id=user_id, event=updated)
