"""Event queries: CRUD, status, and membership."""

from collections.abc import Sequence
from datetime import UTC, date, datetime, time
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from traccio.db.mappers import (
    event_to_row,
    row_to_event,
    row_to_transaction,
)
from traccio.db.models import (
    EventRow,
    TransactionRow,
)
from traccio.db.repositories._common import _transaction_when
from traccio.domain.enums import (
    EventStatus,
    PaletteColor,
)
from traccio.domain.models import (
    Event,
    Transaction,
)


def create_event(session: Session, *, event: Event) -> Event:
    """Persist a new event.

    Writes only the ``events`` row; assigning member transactions is a separate,
    explicit step (see :func:`assign_transaction_to_event`). The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    event : Event
        The domain event to store.

    Returns
    -------
    Event
        The persisted event.
    """
    session.add(event_to_row(event))
    return event


def get_event(session: Session, *, user_id: UUID, event_id: UUID) -> Event | None:
    """Return a single event by id, scoped by ``user_id``.

    Returns ``None`` when no event with that id belongs to the user, so a request
    naming another user's (or an unknown) event cannot read it.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the event; the query is scoped to it.
    event_id : UUID
        The event to fetch.

    Returns
    -------
    Event or None
        The domain event, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(EventRow).where(EventRow.id == event_id, EventRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_event(row)


def list_events(session: Session, user_id: UUID) -> list[Event]:
    """Return the user's events, oldest first.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose events to return; the query is scoped to it.

    Returns
    -------
    list[Event]
        Domain events owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(EventRow).where(EventRow.user_id == user_id).order_by(EventRow.created_at)
    ).all()
    return [row_to_event(row) for row in rows]


def update_event(
    session: Session,
    *,
    user_id: UUID,
    event_id: UUID,
    name: str,
    emoji: str | None,
    color: PaletteColor | None,
    start_date: date | None,
    end_date: date | None,
) -> Event | None:
    """Replace an event's editable fields, scoped by ``user_id``.

    A full replace of ``name``, ``emoji``, ``color`` and the date range — the
    fields the client's single event editor owns (ADR 0027). ``status`` and
    ``created_at`` are not touched (close/reopen has its own write). Returns
    the updated event, or ``None`` if no row matches the user. The caller owns
    the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the event; the update is scoped to it.
    event_id : UUID
        The event to update.
    name : str
        The new name (required; the client never clears it).
    emoji : str or None
        The new emoji, already validated at the API edge, or ``None`` to clear.
    color : PaletteColor or None
        The new colour token, or ``None`` to clear.
    start_date, end_date : date or None
        The new date-range hint, or ``None`` to clear either bound.

    Returns
    -------
    Event or None
        The updated domain event, or ``None`` if not found for this user.
    """
    if get_event(session, user_id=user_id, event_id=event_id) is None:
        return None
    session.execute(
        update(EventRow)
        .where(EventRow.id == event_id, EventRow.user_id == user_id)
        .values(
            name=name,
            emoji=emoji,
            color=color,
            start_date=start_date,
            end_date=end_date,
        )
    )
    return get_event(session, user_id=user_id, event_id=event_id)


def delete_event(session: Session, *, user_id: UUID, event_id: UUID) -> Event | None:
    """Delete an event and return it, clearing its members' ``event_id`` first.

    Deleting an event removes only the grouping — the member transactions survive
    with their ``event_id`` set back to ``None`` (see ``docs/domain.md``). The
    members are cleared explicitly (not via a DB cascade) to stay portable across
    SQLite and PostgreSQL, and so a plain foreign key is not violated when the row
    is dropped. Returns ``None`` when no event with that id belongs to the user.
    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the event; the query and delete are scoped to it.
    event_id : UUID
        The event to delete.

    Returns
    -------
    Event or None
        The deleted event, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(EventRow).where(EventRow.id == event_id, EventRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    event = row_to_event(row)
    session.execute(
        update(TransactionRow)
        .where(TransactionRow.user_id == user_id, TransactionRow.event_id == event_id)
        .values(event_id=None)
    )
    session.delete(row)
    return event


def set_event_status(
    session: Session, *, user_id: UUID, event_id: UUID, status: EventStatus
) -> None:
    """Set an event's ``status``, scoped by ``user_id``.

    The write behind closing or reopening an event; purely organizational, it
    never touches any transaction. Scoped by ``user_id``; a no-op if no row
    matches. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the event; the update is scoped to it.
    event_id : UUID
        The event whose status to set.
    status : EventStatus
        The new status.
    """
    session.execute(
        update(EventRow)
        .where(EventRow.id == event_id, EventRow.user_id == user_id)
        .values(status=status)
    )


def get_transaction_event_id(
    session: Session, *, user_id: UUID, transaction_id: UUID
) -> UUID | None:
    """Return the event a transaction is currently grouped under, or ``None``.

    Scoped by ``user_id``. ``None`` means either the transaction has no event or
    it does not belong to the user; the caller establishes existence separately
    (via :func:`get_transaction`) before interpreting the result.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the query is scoped to it.
    transaction_id : UUID
        The transaction whose membership to read.

    Returns
    -------
    UUID or None
        The current ``event_id`` of the transaction, or ``None``.
    """
    return session.scalars(
        select(TransactionRow.event_id).where(
            TransactionRow.id == transaction_id,
            TransactionRow.user_id == user_id,
        )
    ).one_or_none()


def event_ids_for_transactions(
    session: Session, *, user_id: UUID, transaction_ids: Sequence[UUID]
) -> dict[UUID, UUID]:
    """Return the event membership of a batch of transactions, as a map.

    Scoped by ``user_id``. A single query for the whole page of a
    ``GET /transactions`` response, rather than one :func:`get_transaction_event_id`
    call per row — the batched counterpart to that function. Only entries with
    a non-``None`` ``event_id`` are included, so a caller checks membership
    with a plain ``.get(transaction_id)``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transactions; the query is scoped to it.
    transaction_ids : Sequence[UUID]
        The transactions to look up. An empty sequence returns an empty map
        without querying.

    Returns
    -------
    dict[UUID, UUID]
        Transaction id -> event id, for transactions that belong to one.
    """
    if not transaction_ids:
        return {}
    rows = session.execute(
        select(TransactionRow.id, TransactionRow.event_id).where(
            TransactionRow.user_id == user_id,
            TransactionRow.id.in_(transaction_ids),
            TransactionRow.event_id.is_not(None),
        )
    ).all()
    return {row.id: row.event_id for row in rows if row.event_id is not None}


def assign_transaction_to_event(
    session: Session, *, user_id: UUID, event_id: UUID, transaction_id: UUID
) -> None:
    """Group a transaction under an event, scoped by ``user_id``.

    Sets ``transactions.event_id`` — the explicit-user-action write behind adding
    a transaction to an event. Membership is orthogonal to ``role`` and never
    changes ``effective_amount``. The caller checks the event and transaction
    exist and that the transaction is not already in a different event; this only
    performs the write. Scoped by ``user_id``. The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of both the event and the transaction; the update is scoped to it.
    event_id : UUID
        The event to group the transaction under.
    transaction_id : UUID
        The transaction to assign.
    """
    session.execute(
        update(TransactionRow)
        .where(TransactionRow.id == transaction_id, TransactionRow.user_id == user_id)
        .values(event_id=event_id)
    )


def unassign_transaction_from_event(
    session: Session, *, user_id: UUID, event_id: UUID, transaction_id: UUID
) -> None:
    """Remove a transaction from an event, scoped by ``user_id``.

    Clears ``transactions.event_id`` only when the transaction is currently a
    member of *this* event, so unassigning from the wrong event is a no-op. The
    transaction itself is untouched. Scoped by ``user_id``. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the update is scoped to it.
    event_id : UUID
        The event the transaction should currently belong to.
    transaction_id : UUID
        The transaction to unassign.
    """
    session.execute(
        update(TransactionRow)
        .where(
            TransactionRow.id == transaction_id,
            TransactionRow.user_id == user_id,
            TransactionRow.event_id == event_id,
        )
        .values(event_id=None)
    )


def list_event_members(session: Session, *, user_id: UUID, event_id: UUID) -> list[Transaction]:
    """Return the transactions grouped under one event, scoped by ``user_id``.

    Feeds the pure :func:`~traccio.domain.events.event_total` derivation, so the
    order is not significant; it matches the transaction readers
    (most-recent-first) for consistency.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to return; the query is scoped to it.
    event_id : UUID
        The event whose members to list.

    Returns
    -------
    list[Transaction]
        The event's member transactions (empty if none).
    """
    rows = session.scalars(
        select(TransactionRow)
        .where(TransactionRow.user_id == user_id, TransactionRow.event_id == event_id)
        .order_by(_transaction_when().desc(), TransactionRow.id)
    ).all()
    return [row_to_transaction(row) for row in rows]


def list_event_candidates(
    session: Session,
    *,
    user_id: UUID,
    start: date,
    end: date,
    limit: int = 200,
) -> list[Transaction]:
    """Return the user's un-grouped transactions dated within ``[start, end]``.

    The date-range membership *suggestion* (``docs/domain.md`` §Event: the
    range is a hint, never a rule). A dedicated read rather than another flag
    on :func:`~traccio.db.repositories.transactions.list_transactions`, which
    already carries ten parameters — one module, one responsibility. Only
    ``event_id IS NULL`` rows are returned (a transaction already in an event
    is never a candidate), most-recent-first, capped at ``limit``. The bound
    is the same ``coalesce(booked_at, value_date)`` expression every other
    date filter uses, so a dateless row is naturally excluded.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to consider; the query is scoped to it.
    start, end : date
        Inclusive day bounds; ``end`` is widened to the end of that day.
    limit : int, optional
        Maximum rows to return.

    Returns
    -------
    list[Transaction]
        Candidate transactions, most recent first (empty if none).
    """
    when = _transaction_when()
    lower = datetime.combine(start, time.min, tzinfo=UTC)
    upper = datetime.combine(end, time.max, tzinfo=UTC)
    rows = session.scalars(
        select(TransactionRow)
        .where(
            TransactionRow.user_id == user_id,
            TransactionRow.event_id.is_(None),
            when >= lower,
            when <= upper,
        )
        .order_by(when.desc(), TransactionRow.id)
        .limit(limit)
    ).all()
    return [row_to_transaction(row) for row in rows]
