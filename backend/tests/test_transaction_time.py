"""Tests for the ``transaction_when``/``effective_calendar_date`` derivation.

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented references) — see ``docs/engineering.md``.
"""

from datetime import UTC, date, datetime
from uuid import uuid4

from traccio.domain.enums import KeyStrategy, TransactionStatus
from traccio.domain.models import Transaction
from traccio.domain.money import Money
from traccio.domain.transaction_time import effective_calendar_date, transaction_when

_BOOKED = datetime(2026, 3, 3, 12, 0, tzinfo=UTC)
_VALUE = datetime(2026, 3, 1, 9, 0, tzinfo=UTC)


def _tx(*, booked_at: datetime | None, value_date: datetime | None) -> Transaction:
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-1234, currency="EUR"),
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        booked_at=booked_at,
        value_date=value_date,
        stable_key="TX-01",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def test_transaction_when_prefers_booked_at() -> None:
    tx = _tx(booked_at=_BOOKED, value_date=_VALUE)
    assert transaction_when(tx) == _BOOKED


def test_transaction_when_falls_back_to_value_date() -> None:
    tx = _tx(booked_at=None, value_date=_VALUE)
    assert transaction_when(tx) == _VALUE


def test_transaction_when_is_none_with_neither_date() -> None:
    tx = _tx(booked_at=None, value_date=None)
    assert transaction_when(tx) is None


def test_effective_calendar_date_takes_the_date_part() -> None:
    tx = _tx(booked_at=_BOOKED, value_date=None)
    assert effective_calendar_date(tx) == date(2026, 3, 3)


def test_effective_calendar_date_is_none_with_neither_date() -> None:
    tx = _tx(booked_at=None, value_date=None)
    assert effective_calendar_date(tx) is None
