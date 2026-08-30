"""Deriving the suggested tracking start date (ADR 0024).

The user wants the dashboard and the Movimenti list to begin from a month in
which **every** account already has data — before that, a month shows only the
accounts that happened to be connected earliest, and the totals are
misleading. This module holds the one pure rule that turns each account's
first-movement date into that suggestion.

Imports nothing outside ``domain/``.
"""

from collections.abc import Mapping
from datetime import date
from uuid import UUID


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
