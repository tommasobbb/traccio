"""Tests for the pure planning step of the empty-field repair script.

``repair_empty_transaction_fields.py`` writes to production data, so unlike
the other operational scripts (``eb_smoke.py``, ``eb_field_census.py``) its
pure decision function earns a test — see ``pyproject.toml``'s
``pythonpath`` for how ``scripts/`` becomes importable here.

No network and no database: only :func:`plan_repair`, which decides field
fills from already-fetched data. Every value is synthetic
(`docs/engineering.md`).
"""

from datetime import UTC, datetime
from uuid import uuid4

from repair_empty_transaction_fields import StoredTransactionFields, plan_repair

from traccio.domain.enums import KeyStrategy, TransactionStatus
from traccio.domain.models import Transaction
from traccio.domain.money import Money


def _stored(**overrides: object) -> StoredTransactionFields:
    defaults: dict[str, object] = {
        "id": uuid4(),
        "stable_key": "ENTRY-01",
        "booked_at": None,
        "value_date": None,
        "description": "",
    }
    defaults.update(overrides)
    return StoredTransactionFields(**defaults)  # type: ignore[arg-type]


def _fresh(**overrides: object) -> Transaction:
    defaults: dict[str, object] = {
        "user_id": uuid4(),
        "account_id": uuid4(),
        "money": Money(amount=-1234, currency="EUR"),
        "booked_at": None,
        "value_date": datetime(2026, 8, 20, tzinfo=UTC),
        "description": "TEST CREDITOR 01",
        "status": TransactionStatus.BOOKED,
        "stable_key": "ENTRY-01",
        "key_strategy": KeyStrategy.ENTRY_REFERENCE,
    }
    defaults.update(overrides)
    return Transaction(**defaults)  # type: ignore[arg-type]


def test_fills_every_empty_field_the_fresh_transaction_has() -> None:
    row = _stored()
    fresh = _fresh(booked_at=datetime(2026, 8, 19, tzinfo=UTC))

    plan = plan_repair([row], {"ENTRY-01": fresh})

    assert plan.updates == {
        row.id: {
            "booked_at": fresh.booked_at,
            "value_date": fresh.value_date,
            "description": fresh.description,
        }
    }
    assert plan.rows_matched == 1
    assert plan.rows_unmatched == 0
    assert plan.filled == {"booked_at": 1, "value_date": 1, "description": 1}
    assert plan.still_empty == {}


def test_never_proposes_overwriting_an_already_populated_field() -> None:
    # value_date and description are already set on the stored row; only
    # booked_at is empty. The fresh transaction disagrees on value_date and
    # description, but that must never be proposed as a fill.
    row = _stored(
        value_date=datetime(2020, 1, 1, tzinfo=UTC),
        description="ORIGINAL DESCRIPTION",
    )
    fresh = _fresh(
        booked_at=datetime(2026, 8, 19, tzinfo=UTC),
        value_date=datetime(2099, 1, 1, tzinfo=UTC),
        description="A DIFFERENT DESCRIPTION",
    )

    plan = plan_repair([row], {"ENTRY-01": fresh})

    assert plan.updates == {row.id: {"booked_at": fresh.booked_at}}
    assert plan.filled == {"booked_at": 1}


def test_matched_row_stays_still_empty_when_the_fresh_value_is_itself_empty() -> None:
    row = _stored()
    fresh = _fresh(booked_at=None, description="")

    plan = plan_repair([row], {"ENTRY-01": fresh})

    # value_date is still fillable — only booked_at/description stay empty.
    assert plan.updates == {row.id: {"value_date": fresh.value_date}}
    assert plan.rows_matched == 1
    assert plan.filled == {"value_date": 1}
    assert plan.still_empty == {"booked_at": 1, "description": 1}


def test_unmatched_row_counts_toward_the_history_window_ceiling() -> None:
    # The bank no longer serves this stable_key at all (the ~90-day ceiling).
    row = _stored()

    plan = plan_repair([row], {})

    assert row.id not in plan.updates
    assert plan.rows_matched == 0
    assert plan.rows_unmatched == 1
    assert plan.still_empty == {"booked_at": 1, "value_date": 1, "description": 1}


def test_a_row_with_no_empty_fields_is_matched_but_never_updated() -> None:
    row = _stored(
        booked_at=datetime(2020, 1, 1, tzinfo=UTC),
        value_date=datetime(2020, 1, 1, tzinfo=UTC),
        description="ALREADY THERE",
    )
    fresh = _fresh()

    plan = plan_repair([row], {"ENTRY-01": fresh})

    assert plan.updates == {}
    assert plan.rows_matched == 1
    assert plan.filled == {}
    assert plan.still_empty == {}


def test_counts_aggregate_across_multiple_rows() -> None:
    matched_and_filled = _stored(stable_key="ENTRY-01")
    unmatched = _stored(stable_key="ENTRY-MISSING")
    fresh = _fresh(stable_key="ENTRY-01")

    plan = plan_repair([matched_and_filled, unmatched], {"ENTRY-01": fresh})

    assert plan.rows_matched == 1
    assert plan.rows_unmatched == 1
    assert len(plan.updates) == 1
    assert matched_and_filled.id in plan.updates
    assert unmatched.id not in plan.updates
