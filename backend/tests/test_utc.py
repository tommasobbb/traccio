"""Tests for ``as_aware_utc`` — the shared naive-datetime-as-UTC guard."""

from datetime import UTC, datetime, timedelta, timezone

from traccio.domain.utc import as_aware_utc


def test_a_naive_value_gets_utc_attached() -> None:
    naive = datetime(2026, 3, 3, 12, 0)
    assert as_aware_utc(naive) == datetime(2026, 3, 3, 12, 0, tzinfo=UTC)


def test_an_already_aware_value_is_returned_unchanged() -> None:
    aware = datetime(2026, 3, 3, 12, 0, tzinfo=timezone(timedelta(hours=2)))
    assert as_aware_utc(aware) is aware
