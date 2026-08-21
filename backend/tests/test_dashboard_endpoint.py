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
from traccio.db.models import TransactionRow
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
    engine: Engine, *, user_id: UUID, amount: int, stable_key: str, booked_at: datetime = _IN_PERIOD
) -> str:
    with Session(engine) as session:
        tx = _tx(user_id=user_id, amount=amount, stable_key=stable_key, booked_at=booked_at)
        session.add(tx)
        session.commit()
        return str(tx.id)


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
