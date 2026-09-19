"""Tests for the pure consent-state derivation (``domain/consent``).

Pure unit tests: no database, no network, no wall clock — ``now`` is always
passed in. Fixtures use synthetic values only (round timestamps, invented
institution names) — see ``docs/engineering.md``.
"""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

from traccio.domain import ConnectionStatus, ConsentState, consent_state, days_until_expiry
from traccio.domain.models import Connection

_NOW = datetime(2026, 8, 21, 12, 0, 0, tzinfo=UTC)
_WARNING_WINDOW_DAYS = 14


def _connection(
    *,
    status: ConnectionStatus = ConnectionStatus.ACTIVE,
    expires_at: datetime | None = None,
) -> Connection:
    """Build a synthetic connection."""
    return Connection(
        user_id=uuid4(),
        provider="enable_banking",
        institution_name="TEST BANK",
        country="IT",
        status=status,
        expires_at=expires_at,
    )


def test_pending_passes_through() -> None:
    """A stored PENDING status is not re-read against the clock."""
    connection = _connection(status=ConnectionStatus.PENDING)
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.PENDING
    )


def test_revoked_passes_through() -> None:
    """A stored REVOKED status is terminal regardless of expires_at."""
    connection = _connection(status=ConnectionStatus.REVOKED, expires_at=_NOW + timedelta(days=100))
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.REVOKED
    )


def test_error_passes_through() -> None:
    """A stored ERROR status is terminal regardless of expires_at."""
    connection = _connection(status=ConnectionStatus.ERROR, expires_at=_NOW + timedelta(days=100))
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.ERROR
    )


def test_stored_expired_passes_through() -> None:
    """A provider-reported EXPIRED status stays EXPIRED."""
    connection = _connection(status=ConnectionStatus.EXPIRED)
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.EXPIRED
    )


def test_active_with_no_expiry_stays_active() -> None:
    """No recorded expiry is not the same as expired."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=None)
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.ACTIVE
    )


def test_active_well_before_expiry_stays_active() -> None:
    """Active and far from the warning window reads as plain active."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=_NOW + timedelta(days=60))
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.ACTIVE
    )


def test_active_within_warning_window_is_expiring_soon() -> None:
    """Inside the warning window, active becomes expiring_soon."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=_NOW + timedelta(days=10))
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.EXPIRING_SOON
    )


def test_active_past_expiry_is_derived_expired() -> None:
    """A stored ACTIVE connection past its expires_at is derived as expired."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=_NOW - timedelta(days=1))
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.EXPIRED
    )


def test_active_at_the_exact_expiry_instant_is_expired() -> None:
    """The boundary instant itself counts as expired, not one more day of grace."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=_NOW)
    assert (
        consent_state(connection, now=_NOW, warning_window_days=_WARNING_WINDOW_DAYS)
        is ConsentState.EXPIRED
    )


def test_days_until_expiry_none_when_unset() -> None:
    """No expires_at means no figure to show, not zero."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=None)
    assert days_until_expiry(connection, now=_NOW) is None


def test_days_until_expiry_counts_forward() -> None:
    """A future expiry counts whole days remaining."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=_NOW + timedelta(days=30))
    assert days_until_expiry(connection, now=_NOW) == 30


def test_days_until_expiry_is_negative_once_lapsed() -> None:
    """A past expiry reports a negative count, not clamped to zero."""
    connection = _connection(status=ConnectionStatus.ACTIVE, expires_at=_NOW - timedelta(days=5))
    assert days_until_expiry(connection, now=_NOW) == -5
