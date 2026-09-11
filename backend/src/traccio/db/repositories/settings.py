"""User-settings queries: the tracking-start date and its supporting reads."""

from datetime import UTC, date, datetime
from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.models import (
    TransactionRow,
    UserRow,
)
from traccio.db.repositories._common import _transaction_when


def get_tracking_start_date(session: Session, *, user_id: UUID) -> date | None:
    """Return the user's ``tracking_start_date`` (ADR 0024), or ``None``.

    ``None`` for a user with no row yet (the dev user in a fresh test db never
    inserts one) and for a user who has never set it — both mean "no floor".
    Scoped by ``user_id``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        The user whose setting to read.

    Returns
    -------
    date or None
        The stored floor, or ``None``.
    """
    row = session.get(UserRow, user_id)
    return row.tracking_start_date if row is not None else None


def set_tracking_start_date(session: Session, *, user_id: UUID, value: date | None) -> None:
    """Set (or clear, with ``None``) the user's ``tracking_start_date``.

    Upserts the ``users`` row: a fresh test database only ever holds the ids
    referenced by other rows, never a ``users`` row for the dev user, so this
    inserts one on first use (stamping ``created_at`` now) rather than failing.
    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        The user whose setting to write.
    value : date or None
        The new floor, or ``None`` to clear it (show everything again).
    """
    row = session.get(UserRow, user_id)
    if row is None:
        session.add(UserRow(id=user_id, created_at=datetime.now(UTC), tracking_start_date=value))
    else:
        row.tracking_start_date = value


def get_meal_vouchers_enabled(session: Session, *, user_id: UUID) -> bool:
    """Return whether the user's meal-vouchers dashboard breakout is on (ADR 0029).

    ``False`` for a user with no row yet — the same "no row means the
    default" posture as :func:`get_tracking_start_date`. Scoped by
    ``user_id``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        The user whose setting to read.

    Returns
    -------
    bool
        Whether the breakout is enabled.
    """
    row = session.get(UserRow, user_id)
    return row.meal_vouchers_enabled if row is not None else False


def set_meal_vouchers_enabled(session: Session, *, user_id: UUID, value: bool) -> None:
    """Set the user's meal-vouchers dashboard breakout on or off.

    Upserts the ``users`` row, same as :func:`set_tracking_start_date`. The
    caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        The user whose setting to write.
    value : bool
        The new state.
    """
    row = session.get(UserRow, user_id)
    if row is None:
        session.add(UserRow(id=user_id, created_at=datetime.now(UTC), meal_vouchers_enabled=value))
    else:
        row.meal_vouchers_enabled = value


def earliest_transaction_dates_by_account(session: Session, *, user_id: UUID) -> dict[UUID, date]:
    """Return each account's earliest dated movement (ADR 0024).

    Groups the user's transactions by account and takes
    ``min(coalesce(booked_at, value_date))`` — the same "when" expression every
    other date filter uses. An account whose every movement is dateless (no
    ``booked_at`` and no ``value_date``) has a ``NULL`` minimum and is left
    out; so is an account with no movements at all. The caller diffs this
    against the full account list to show the user which accounts constrain
    the suggestion and which have nothing yet. Scoped by ``user_id``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        The user whose transactions to scan.

    Returns
    -------
    dict[UUID, date]
        Account id → earliest movement date, only for accounts with at least
        one dated movement.
    """
    when = _transaction_when()
    rows = session.execute(
        select(TransactionRow.account_id, func.min(when))
        .where(TransactionRow.user_id == user_id)
        .group_by(TransactionRow.account_id)
    ).all()
    result: dict[UUID, date] = {}
    for account_id, earliest in rows:
        if earliest is None:
            continue
        result[account_id] = earliest.date() if isinstance(earliest, datetime) else earliest
    return result
