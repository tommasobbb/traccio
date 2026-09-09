"""Deriving the suggested tracking start date (ADR 0024).

The user wants the dashboard and the Movimenti list to begin from a month in
which **every** account already has data — before that, a month shows only the
accounts that happened to be connected earliest, and the totals are
misleading. This module holds the one pure rule that turns each account's
first-movement date into that suggestion, plus the pure predicate that decides
whether a single transaction falls on or after that floor.

Imports nothing outside ``domain/``.
"""

from collections.abc import Mapping
from datetime import UTC, date, datetime, time
from uuid import UUID

from traccio.domain.models import Transaction


def suggest_tracking_start(earliest_by_account: Mapping[UUID, date]) -> date | None:
    """The first day of the earliest month every account fully covers.

    The latest-starting account is the constraint. If its first movement falls
    on the 1st, that whole month is covered by everyone and is the suggestion;
    otherwise the month is partial for that account, so the suggestion is the
    1st of the **next** month.

    Parameters
    ----------
    earliest_by_account : Mapping[UUID, date]
        Each account's earliest dated movement. Accounts with no dated
        movement are simply absent — they place no constraint (nothing to
        line up), and the caller lists them separately for the user.

    Returns
    -------
    date or None
        The suggested first tracked day, or ``None`` when no account has a
        dated movement (nothing to suggest from).
    """
    if not earliest_by_account:
        return None
    latest = max(earliest_by_account.values())
    if latest.day == 1:
        return latest
    if latest.month == 12:
        return date(latest.year + 1, 1, 1)
    return date(latest.year, latest.month + 1, 1)


def is_within_tracking(transaction: Transaction, tracking_start: date | None) -> bool:
    """Whether a transaction falls on or after the tracking-start floor.

    The pure, single-transaction counterpart of the SQL bound applied by
    ``db.repositories`` to the Movimenti list and the dashboard (ADR 0024 §3):
    ``coalesce(booked_at, value_date) >= <UTC midnight of tracking_start>``.
    Used where the floor must be applied to transactions already loaded in
    Python — the advances list and its cross-advance summary (ADR 0026), which
    must agree with the dashboard about which movements count.

    Parameters
    ----------
    transaction : Transaction
        The transaction to test. Its "when" is ``booked_at`` if set, else
        ``value_date``; a naive datetime is read as UTC.
    tracking_start : date or None
        The user's floor. ``None`` — no floor set — lets every transaction
        through, matching the ``None``-in/``None``-out of the SQL helper.

    Returns
    -------
    bool
        ``True`` if there is no floor, or the transaction's "when" is on or
        after the first instant (UTC) of ``tracking_start``. A transaction
        with neither date is excluded whenever a floor is set — the same way
        every other date bound in Traccio treats a dateless row.
    """
    if tracking_start is None:
        return True
    when = transaction.booked_at or transaction.value_date
    if when is None:
        return False
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    return when >= datetime.combine(tracking_start, time.min, tzinfo=UTC)
