"""Tests for ``domain/tracking.py`` (ADR 0024): ``suggest_tracking_start`` and
``is_within_tracking``.

Pure: no database, no clock. Synthetic account ids, dates and transactions.
"""

from datetime import UTC, date, datetime
from uuid import uuid4

from traccio.domain import KeyStrategy, Money, Transaction, TransactionStatus
from traccio.domain.tracking import is_within_tracking, suggest_tracking_start


def _tx(
    *,
    booked_at: datetime | None = None,
    value_date: datetime | None = None,
) -> Transaction:
    """Build a synthetic transaction carrying only the dates under test."""
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-5000, currency="EUR"),
        booked_at=booked_at,
        value_date=value_date,
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        stable_key=f"TX-{uuid4()}",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def test_no_accounts_has_no_suggestion() -> None:
    assert suggest_tracking_start({}) is None


def test_a_mid_month_start_suggests_the_first_of_the_next_month() -> None:
    assert suggest_tracking_start({uuid4(): date(2026, 6, 15)}) == date(2026, 7, 1)


def test_a_first_of_month_start_suggests_that_same_month() -> None:
    # The whole month is already covered — no need to skip it.
    assert suggest_tracking_start({uuid4(): date(2026, 6, 1)}) == date(2026, 6, 1)


def test_the_latest_starting_account_is_the_constraint() -> None:
    earliest = {
        uuid4(): date(2026, 3, 1),
        uuid4(): date(2026, 6, 15),
        uuid4(): date(2026, 1, 20),
    }
    assert suggest_tracking_start(earliest) == date(2026, 7, 1)


def test_all_accounts_starting_on_the_first_suggests_the_latest_such_month() -> None:
    earliest = {uuid4(): date(2026, 3, 1), uuid4(): date(2026, 6, 1)}
    assert suggest_tracking_start(earliest) == date(2026, 6, 1)


def test_a_december_start_rolls_into_january_of_the_next_year() -> None:
    assert suggest_tracking_start({uuid4(): date(2026, 12, 9)}) == date(2027, 1, 1)


# --- is_within_tracking ---------------------------------------------------------


def test_no_floor_lets_every_transaction_through() -> None:
    assert is_within_tracking(_tx(booked_at=datetime(2020, 1, 1, tzinfo=UTC)), None) is True
    assert is_within_tracking(_tx(booked_at=None, value_date=None), None) is True


def test_a_transaction_on_or_after_the_floor_is_within() -> None:
    floor = date(2026, 7, 1)
    assert is_within_tracking(_tx(booked_at=datetime(2026, 7, 1, tzinfo=UTC)), floor) is True
    assert is_within_tracking(_tx(booked_at=datetime(2026, 9, 3, 14, tzinfo=UTC)), floor) is True


def test_a_transaction_before_the_floor_is_outside() -> None:
    floor = date(2026, 7, 1)
    just_before = _tx(booked_at=datetime(2026, 6, 30, 23, 59, tzinfo=UTC))
    assert is_within_tracking(just_before, floor) is False


def test_falls_back_to_value_date_when_booked_at_is_missing() -> None:
    floor = date(2026, 7, 1)
    assert is_within_tracking(_tx(value_date=datetime(2026, 8, 1, tzinfo=UTC)), floor) is True
    assert is_within_tracking(_tx(value_date=datetime(2026, 5, 1, tzinfo=UTC)), floor) is False


def test_a_dateless_transaction_is_excluded_when_a_floor_is_set() -> None:
    assert is_within_tracking(_tx(booked_at=None, value_date=None), date(2026, 7, 1)) is False


def test_a_naive_when_is_read_as_utc() -> None:
    floor = date(2026, 7, 1)
    assert is_within_tracking(_tx(booked_at=datetime(2026, 7, 2)), floor) is True
    assert is_within_tracking(_tx(booked_at=datetime(2026, 6, 1)), floor) is False
