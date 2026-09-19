"""Sync-run history queries (ADR 0010)."""

from datetime import datetime
from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    row_to_sync_run,
    sync_run_to_row,
)
from traccio.db.models import (
    SyncRunRow,
)
from traccio.domain.enums import SyncRunOutcome
from traccio.domain.models import (
    SyncRun,
)

# The outcomes that consumed a real background fetch — see
# `SyncRunOutcome.counts_toward_budget`'s docstring for why a skip must not
# be one of them (ADR 0037).
_BUDGET_COUNTED_OUTCOMES = [
    outcome for outcome in SyncRunOutcome if outcome.counts_toward_budget
]


def record_sync_run(session: Session, *, sync_run: SyncRun) -> SyncRun:
    """Insert one sync run record.

    Plain insert, never an upsert — every attempt (including a skip) is its
    own immutable row (see the domain docstring). The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    sync_run : SyncRun
        The run to persist.

    Returns
    -------
    SyncRun
        The persisted run, unchanged.
    """
    row = sync_run_to_row(sync_run)
    session.add(row)
    return row_to_sync_run(row)


def count_recent_sync_runs(session: Session, *, connection_id: UUID, since: datetime) -> int:
    """Count *budget-counted* sync runs for one connection since ``since``.

    The read side of the background fetch budget
    (:func:`~traccio.domain.sync_schedule.sync_decision`): the budget is
    counted in *runs that actually reached the provider*, not raw HTTP calls
    (docs/openbanking.md's "~4 background fetches per day" is read as "~4
    sync attempts," since one run already makes several provider calls
    internally) — and, since ADR 0037, not skips either
    (:attr:`~traccio.domain.enums.SyncRunOutcome.counts_toward_budget`). A
    skip means a decision was evaluated, but calls no bank at all; counting
    it here previously made the scheduler starve itself (see that
    property's docstring for the exact mechanism this fixes).

    Not scoped by ``user_id``: a connection's own id already scopes it to one
    user (``connections.user_id``), and the caller (the scheduler) already
    holds a connection it fetched user-scoped.

    Parameters
    ----------
    session : Session
        Active database session.
    connection_id : UUID
        The connection to count runs for.
    since : datetime
        Only runs with ``started_at >= since`` count.

    Returns
    -------
    int
        How many budget-counted runs are on record for this connection since
        ``since``.
    """
    return (
        session.scalars(
            select(func.count(SyncRunRow.id)).where(
                SyncRunRow.connection_id == connection_id,
                SyncRunRow.started_at >= since,
                SyncRunRow.outcome.in_(_BUDGET_COUNTED_OUTCOMES),
            )
        ).one()
        or 0
    )


def oldest_recent_sync_run_started_at(
    session: Session, *, connection_id: UUID, since: datetime
) -> datetime | None:
    """Return the earliest budget-counted ``started_at`` since ``since``.

    The read side of "when does the background budget next free a slot" —
    once this run ages past the rolling window, the count
    :func:`count_recent_sync_runs` returns for the same ``since`` drops by
    one (assuming no newer run has landed since — an estimate, not a
    promise). See :func:`~traccio.domain.sync_schedule.next_sync_eligible_at`.
    Filtered to the same budget-counted outcomes as
    :func:`count_recent_sync_runs` (ADR 0037) — a skip row is not what's
    occupying the slot, so it must not be what's projected to free it.

    Not scoped by ``user_id``, for the same reason as
    :func:`count_recent_sync_runs`.

    Parameters
    ----------
    session : Session
        Active database session.
    connection_id : UUID
        The connection to look at.
    since : datetime
        Only runs with ``started_at >= since`` are considered.

    Returns
    -------
    datetime or None
        The earliest ``started_at`` in the window, or ``None`` if there are
        no budget-counted runs in it.
    """
    return session.scalars(
        select(func.min(SyncRunRow.started_at)).where(
            SyncRunRow.connection_id == connection_id,
            SyncRunRow.started_at >= since,
            SyncRunRow.outcome.in_(_BUDGET_COUNTED_OUTCOMES),
        )
    ).one()


def list_sync_runs(
    session: Session, *, user_id: UUID, connection_id: UUID | None = None, limit: int = 50
) -> list[SyncRun]:
    """Return sync runs, most recent first, for debugging and verification.

    Scoped by ``user_id``; ``connection_id`` narrows to one connection when
    given.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose runs to return; the query is scoped to it.
    connection_id : UUID or None, optional
        When given, restrict to this connection (still scoped by ``user_id``).
    limit : int, optional
        Maximum number of rows to return.

    Returns
    -------
    list[SyncRun]
        Domain sync runs (empty if none), most recent first.
    """
    query = select(SyncRunRow).where(SyncRunRow.user_id == user_id)
    if connection_id is not None:
        query = query.where(SyncRunRow.connection_id == connection_id)
    query = query.order_by(SyncRunRow.started_at.desc(), SyncRunRow.id).limit(limit)
    rows = session.scalars(query).all()
    return [row_to_sync_run(row) for row in rows]
