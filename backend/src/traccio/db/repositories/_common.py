"""Query expressions shared across repository submodules.

The timestamp coalescing and tracking-start floor used by both the
transaction reads and ``events.list_event_members`` — kept here so neither
submodule has to import the other."""

from datetime import UTC, date, datetime, time
from typing import TYPE_CHECKING

from sqlalchemy import func

if TYPE_CHECKING:
    from sqlalchemy import ColumnElement

from traccio.db.models import (
    TransactionRow,
)


def _transaction_when() -> "ColumnElement[datetime | None]":
    """The single "when did this happen" expression for a transaction row.

    ``coalesce(booked_at, value_date)`` — a pending row with no ``booked_at``
    falls back to its ``value_date``. Every query that orders or filters
    transactions by date uses this same expression, so a period filter (e.g.
    :func:`list_transactions`'s ``start``/``end``) can never disagree with the
    ordering, or with another query's own period filter, about which date a
    row belongs to.

    Returns
    -------
    ColumnElement[datetime | None]
        A SQL expression usable in ``.where()``/``.order_by()``.
    """
    return func.coalesce(TransactionRow.booked_at, TransactionRow.value_date)


def _tracking_floor(tracking_start: date | None) -> datetime | None:
    """The ``coalesce(booked_at, value_date)`` lower bound for a tracking start.

    ADR 0024: the user's ``tracking_start_date`` is a whole-day boundary — the
    first instant of that day in UTC. ``None`` in, ``None`` out (no floor). A
    row with no date at all is excluded by this bound, the same way any
    ``start``/``end`` bound already treats a dateless row.
    """
    if tracking_start is None:
        return None
    return datetime.combine(tracking_start, time.min, tzinfo=UTC)
