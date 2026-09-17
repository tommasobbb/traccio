"""Reading a naive datetime as UTC.

SQLite (used in dev and by the test suite; PostgreSQL is the eventual
production target) discards timezone info on a ``DateTime(timezone=True))``
column, so a value stored as UTC comes back naive. Every timestamp in this
system is UTC (root ``CLAUDE.md``: ``datetime.now(UTC)``), so treating a
naive value as UTC is the correct reading, not a guess.

Before this module existed, this same one-line guard was written out
independently in eight places — three of them under their own locally-named
private function (two of those with the exact same name and body) — across
``domain/``, ``services/``, ``db/``, and ``providers/``. This module holds it
once; every other module imports it.

Imports nothing outside ``domain/``.
"""

from datetime import UTC, datetime


def as_aware_utc(value: datetime) -> datetime:
    """Return ``value``, defaulting a naive value to UTC.

    Parameters
    ----------
    value : datetime
        A possibly-naive datetime, read from storage or a parsed string.

    Returns
    -------
    datetime
        ``value`` unchanged if already timezone-aware, otherwise ``value``
        with ``tzinfo=UTC`` attached.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
