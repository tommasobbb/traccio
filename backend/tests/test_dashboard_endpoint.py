"""Tests for ``GET /dashboard/summary``.

The app is built via the factory and its ``get_session`` dependency is
overridden to a shared in-memory SQLite engine, so the endpoint is exercised
end to end (routing, response schema, repository query, advance share
resolution) without a running PostgreSQL. Values are synthetic (see
``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.base import Base
from traccio.db.models import CategoryRow, TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, TransactionStatus

_IN_PERIOD = datetime(2026, 8, 15, tzinfo=UTC)
_BEFORE_PERIOD = datetime(2026, 7, 1, tzinfo=UTC)


def _tx(
    *,
    user_id: UUID,
    amount: int,
    stable_key: str,
    booked_at: datetime = _IN_PERIOD,
    confirmed_category_id: UUID | None = None,
) -> TransactionRow:
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=uuid4(),
        amount=amount,
        currency="EUR",
        booked_at=booked_at,
        value_date=booked_at,
        description="TEST MERCHANT 01",
        display_description=None,
        status=TransactionStatus.BOOKED,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
        confirmed_category_id=confirmed_category_id,
    )


def _client(engine: Engine) -> TestClient:
    def override_get_session() -> Iterator[Session]:
        session = Session(engine)
        try:
            yield session
        finally:
            session.close()

    app = create_app()
    app.dependency_overrides[get_session] = override_get_session
    return TestClient(app)


def _sqlite_engine() -> Engine:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _seed_tx(
    engine: Engine,
    *,
    user_id: UUID,
    amount: int,
    stable_key: str,
    booked_at: datetime = _IN_PERIOD,
    confirmed_category_id: UUID | None = None,
) -> str:
    with Session(engine) as session:
        tx = _tx(
            user_id=user_id,
            amount=amount,
            stable_key=stable_key,
            booked_at=booked_at,
            confirmed_category_id=confirmed_category_id,
        )
        session.add(tx)
        session.commit()
        return str(tx.id)


def _seed_category(engine: Engine, *, user_id: UUID, name: str) -> str:
    with Session(engine) as session:
        category = CategoryRow(id=uuid4(), user_id=user_id, name=name, created_at=_IN_PERIOD)
        session.add(category)
        session.commit()
        return str(category.id)


def test_summary_with_only_personal_transactions() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="SPEND")
    _seed_tx(engine, user_id=dev_user_id, amount=2000, stable_key="INCOME")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    assert response.json() == {
        "currencies": [
            {
                "currency": "EUR",
                "spending": 5000,
                "income": 2000,
                "net": -3000,
                "transaction_count": 2,
                "by_category": [
                    {
                        "category_id": None,
                        "category_name": None,
                        "spending": 5000,
                        "income": 2000,
                        "transaction_count": 2,
                    }
                ],
                "by_day": [
                    {
                        "date": "2026-08-15",
                        "spending": 5000,
                        "income": 2000,
                        "transaction_count": 2,
                    }
                ],
            }
        ]
    }


def test_summary_shows_advance_share_not_full_amount() -> None:
    """This is the roadmap's M2 'done when': tag a real advance and see the
    dashboard show the actual share, not the full amount."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-100000, stable_key="TRIP")  # €1000
    client = _client(engine)
    advance_response = client.post(
        "/advances", json={"transaction_id": tx_id, "own_share": 20000, "participants": []}
    )
    assert advance_response.status_code == 201

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["spending"] == 20000
    assert summary["transaction_count"] == 1


def test_summary_excludes_a_confirmed_transfer() -> None:
    """A transfer between own accounts is not spending — see ADR 0007."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="OUT")
    in_id = _seed_tx(engine, user_id=dev_user_id, amount=5000, stable_key="IN")
    _seed_tx(engine, user_id=dev_user_id, amount=-1200, stable_key="PERSONAL")
    client = _client(engine)
    confirm = client.post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    )
    assert confirm.status_code == 201

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    # Only the untouched personal spend counts; the confirmed transfer pair
    # contributes zero to both spending and income.
    assert summary["spending"] == 1200
    assert summary["income"] == 0
    assert summary["transaction_count"] == 3


def test_summary_filters_by_period() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="OLD", booked_at=_BEFORE_PERIOD)
    _seed_tx(engine, user_id=dev_user_id, amount=-3000, stable_key="NEW", booked_at=_IN_PERIOD)
    client = _client(engine)

    response = client.get(
        "/dashboard/summary",
        params={"start": "2026-08-01T00:00:00Z", "end": "2026-09-01T00:00:00Z"},
    )

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["spending"] == 3000
    assert summary["transaction_count"] == 1


def test_summary_with_no_transactions_returns_no_currencies() -> None:
    engine = _sqlite_engine()
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    assert response.json() == {"currencies": []}


def test_summary_is_user_scoped() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=stranger_id, amount=-9999, stable_key="STRANGER")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    assert response.json() == {"currencies": []}


def test_summary_by_category_resolves_the_category_name() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    groceries_id = _seed_category(engine, user_id=dev_user_id, name="Groceries")
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-3000,
        stable_key="GROCERIES",
        confirmed_category_id=UUID(groceries_id),
    )
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["by_category"] == [
        {
            "category_id": groceries_id,
            "category_name": "Groceries",
            "spending": 3000,
            "income": 0,
            "transaction_count": 1,
        }
    ]


def test_summary_by_category_has_a_null_bucket_for_uncategorized() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    groceries_id = _seed_category(engine, user_id=dev_user_id, name="Groceries")
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-3000,
        stable_key="GROCERIES",
        confirmed_category_id=UUID(groceries_id),
    )
    _seed_tx(engine, user_id=dev_user_id, amount=-1000, stable_key="UNCATEGORIZED")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    by_category_ids = {entry["category_id"] for entry in summary["by_category"]}
    assert None in by_category_ids
    none_entry = next(e for e in summary["by_category"] if e["category_id"] is None)
    assert none_entry["category_name"] is None
    assert none_entry["spending"] == 1000


def test_summary_by_day_buckets_across_multiple_days() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    day_one = datetime(2026, 8, 10, tzinfo=UTC)
    day_two = datetime(2026, 8, 12, tzinfo=UTC)
    _seed_tx(engine, user_id=dev_user_id, amount=-1000, stable_key="DAY1", booked_at=day_one)
    _seed_tx(engine, user_id=dev_user_id, amount=-2500, stable_key="DAY2A", booked_at=day_two)
    _seed_tx(engine, user_id=dev_user_id, amount=500, stable_key="DAY2B", booked_at=day_two)
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["by_day"] == [
        {"date": "2026-08-10", "spending": 1000, "income": 0, "transaction_count": 1},
        {"date": "2026-08-12", "spending": 2500, "income": 500, "transaction_count": 2},
    ]


def test_summary_by_day_excludes_a_row_with_no_date_but_keeps_it_in_totals() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        tx = _tx(user_id=dev_user_id, amount=-4000, stable_key="NO_DATE")
        tx.booked_at = None
        tx.value_date = None
        session.add(tx)
        session.commit()
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["spending"] == 4000
    assert summary["transaction_count"] == 1
    assert summary["by_day"] == []


def test_summary_never_resolves_another_users_category_name() -> None:
    """A category id can only ever come from this user's own transactions
    (every query is user_id-scoped), but the name lookup itself must not leak
    another user's category row even if ids collided by coincidence."""
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    _seed_category(engine, user_id=stranger_id, name="Stranger's category")
    _seed_tx(engine, user_id=dev_user_id, amount=-1000, stable_key="PERSONAL")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    names = {entry["category_name"] for entry in summary["by_category"]}
    assert "Stranger's category" not in names
