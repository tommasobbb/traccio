"""The "when did this happen" derivation for a transaction.

The single place ``transaction.booked_at or transaction.value_date`` is
written, mirroring :func:`traccio.db.repositories._common._transaction_when`'s
SQL ``coalesce`` — so a period filter, an ordering, a bucket, a tracking-start
check, and a transfer-detection window can never disagree about which date a
row belongs to. Before this module existed, five call sites each wrote the
coalescing inline or under a locally-named private function; drifting one of
them (a typo'd fallback order, a forgotten ``is None`` guard) would have
silently misdated a subset of transactions with no test catching it, the
same class of risk ``effective_amount`` is deliberately protected against.

This module imports nothing outside ``domain/``.
"""

from datetime import date, datetime

from traccio.domain.models import Transaction


def transaction_when(transaction: Transaction) -> datetime | None:
    """The raw "when" value for ``transaction``: ``booked_at``, else ``value_date``.

    Returned as-is — naive if the row came back naive from SQLite, aware if
    from Postgres; a caller that needs a guaranteed-aware value coerces it
    itself. A caller that needs a calendar date uses
    :func:`effective_calendar_date` instead of calling ``.date()`` here,
    since that silently loses ``None``-safety.

    Parameters
    ----------
    transaction : Transaction
        The transaction to read.

    Returns
    -------
    datetime or None
        ``transaction.booked_at or transaction.value_date`` — ``None`` only
        when both are unset (a transaction with no date at all).
    """
    return transaction.booked_at or transaction.value_date


def effective_calendar_date(transaction: Transaction) -> date | None:
    """The calendar date :func:`transaction_when` falls on, or ``None``.

    Used where only the day matters, not the time of day (FX conversion picks
    a rate by calendar date, not by instant).

    Parameters
    ----------
    transaction : Transaction
        The transaction to read.

    Returns
    -------
    date or None
        ``transaction_when(transaction).date()``, or ``None`` if unset.
    """
    when = transaction_when(transaction)
    return when.date() if when is not None else None
