"""Derive the actual, time-aware state of a bank consent.

A :class:`~traccio.domain.models.Connection` stores
:class:`~traccio.domain.enums.ConnectionStatus`, written only when the provider
reports something (activation, revocation, an error). It says nothing about the
180-day consent window elapsing on its own — ``docs/openbanking.md``:
"an expired connection silently stops producing data" if nothing checks this.

This module holds the single derivation that answers "is this consent still
good, right now" — sibling to
:func:`~traccio.domain.effective_amount.effective_amount` and
:func:`~traccio.domain.categories.effective_category`: computed once here, never
recomputed by a service or the client. Deliberately **derived, not stored** —
the same reasoning as ADR 0004's ``settled``: a stored expiry flag needs a
background job to stay true and is wrong between runs, while deriving it from
``now`` is correct the instant it is read, with no scheduler required.

This module imports nothing outside ``domain/``.
"""

from datetime import UTC, datetime

from traccio.domain.enums import ConnectionStatus, ConsentState
from traccio.domain.models import Connection


def _expiry_as_aware_utc(connection: Connection) -> datetime | None:
    """Return ``connection.expires_at``, defaulting a naive value to UTC.

    SQLite (used in dev and by the test suite; PostgreSQL is the eventual
    target — see ``tasks/backlog.md``) discards timezone info on a
    ``DateTime(timezone=True)`` column, so a value stored as UTC comes back
    naive. Every timestamp in this system is UTC (root ``CLAUDE.md``:
    ``datetime.now(UTC)``), so treating a naive value as UTC is the correct
    reading, not a guess — the same guard the Enable Banking adapter applies
    when parsing provider dates (``providers/enable_banking/transactions.py``).
    """
    expires_at = connection.expires_at
    if expires_at is None or expires_at.tzinfo is not None:
        return expires_at
    return expires_at.replace(tzinfo=UTC)


def consent_state(
    connection: Connection, *, now: datetime, warning_window_days: int
) -> ConsentState:
    """Return the actual state of ``connection``'s consent as of ``now``.

    A stored :attr:`~traccio.domain.enums.ConnectionStatus.PENDING`,
    :attr:`~traccio.domain.enums.ConnectionStatus.REVOKED`, or
    :attr:`~traccio.domain.enums.ConnectionStatus.ERROR` passes through
    unchanged — the provider already told us the terminal or pre-consent truth,
    and no clock reading overrides it. Only a stored
    :attr:`~traccio.domain.enums.ConnectionStatus.ACTIVE` is re-read against
    ``expires_at``: past expiry it is :attr:`~traccio.domain.enums.ConsentState.EXPIRED`,
    within ``warning_window_days`` of expiry it is
    :attr:`~traccio.domain.enums.ConsentState.EXPIRING_SOON`, otherwise it stays
    :attr:`~traccio.domain.enums.ConsentState.ACTIVE`. An active connection with
    ``expires_at is None`` (expiry not yet known) stays
    :attr:`~traccio.domain.enums.ConsentState.ACTIVE` — no expiry recorded is not
    the same as expired.

    Parameters
    ----------
    connection : Connection
        The connection to evaluate.
    now : datetime
        The current time, timezone-aware. Passed in rather than read internally
        so this function stays testable with no clock.
    warning_window_days : int
        How many whole days before ``expires_at`` count as "expiring soon" (see
        ``Settings.consent_warning_window_days``).

    Returns
    -------
    ConsentState
        The consent's actual, time-aware state.
    """
    if connection.status is ConnectionStatus.PENDING:
        return ConsentState.PENDING
    if connection.status is ConnectionStatus.REVOKED:
        return ConsentState.REVOKED
    if connection.status is ConnectionStatus.ERROR:
        return ConsentState.ERROR
    if connection.status is ConnectionStatus.EXPIRED:
        return ConsentState.EXPIRED

    # ConnectionStatus.ACTIVE: re-read against the clock.
    expires_at = _expiry_as_aware_utc(connection)
    if expires_at is None:
        return ConsentState.ACTIVE
    remaining = expires_at - now
    if remaining.total_seconds() <= 0:
        return ConsentState.EXPIRED
    if remaining.days < warning_window_days:
        return ConsentState.EXPIRING_SOON
    return ConsentState.ACTIVE


def days_until_expiry(connection: Connection, *, now: datetime) -> int | None:
    """Return whole days until ``connection.expires_at``, or ``None``.

    ``None`` when ``expires_at`` is unset. A negative value means the consent
    has already lapsed — the caller reads :func:`consent_state` for the
    authoritative expired/not-expired call; this is a display figure.

    Parameters
    ----------
    connection : Connection
        The connection to evaluate.
    now : datetime
        The current time, timezone-aware.

    Returns
    -------
    int or None
        Whole days remaining (negative if past), or ``None`` if ``expires_at``
        is unset.
    """
    expires_at = _expiry_as_aware_utc(connection)
    if expires_at is None:
        return None
    return (expires_at - now).days
