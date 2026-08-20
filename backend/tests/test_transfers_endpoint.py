"""Tests for ``GET /transfers/suggestions``.

The app is built via the factory and its ``get_session`` dependency is overridden
to a shared in-memory SQLite engine, so the endpoint is exercised end to end
(routing, detection, response schema) without a running PostgreSQL. Values are
synthetic (see ``.claude/rules/data-safety.md``).
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

_DAY = datetime(2026, 3, 1, tzinfo=UTC)


def _tx(
    *,
    user_id: UUID,
    account_id: UUID,
    amount: int,
    stable_key: str,
) -> TransactionRow:
    """Build a synthetic booked transaction row."""
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=account_id,
        amount=amount,
        currency="EUR",
        booked_at=_DAY,
        value_date=_DAY,
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


def test_suggests_a_matching_pair_for_the_current_user() -> None:
    dev_user_id = get_settings().dev_user_id
    account_a, account_b = uuid4(), uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        out = _tx(user_id=dev_user_id, account_id=account_a, amount=-50000, stable_key="TX-OUT")
        inc = _tx(user_id=dev_user_id, account_id=account_b, amount=50000, stable_key="TX-IN")
        session.add_all([out, inc])
        session.commit()
        out_id, in_id = str(out.id), str(inc.id)

    response = _client(engine).get("/transfers/suggestions")

    assert response.status_code == 200
    [suggestion] = response.json()["suggestions"]
    assert suggestion["outgoing_transaction_id"] == out_id
    assert suggestion["incoming_transaction_id"] == in_id
    assert suggestion["currency"] == "EUR"
    assert suggestion["amount_delta"] == 0


def test_never_pairs_across_users() -> None:
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        # The user's outgoing leg and a stranger's incoming leg must not pair —
        # the query is scoped to the user, so the stranger's row is never seen.
        session.add_all(
            [
                _tx(user_id=dev_user_id, account_id=uuid4(), amount=-50000, stable_key="TX-MINE"),
                _tx(user_id=stranger_id, account_id=uuid4(), amount=50000, stable_key="TX-THEIRS"),
            ]
        )
        session.commit()

    response = _client(engine).get("/transfers/suggestions")

    assert response.status_code == 200
    assert response.json() == {"suggestions": []}


def test_empty_when_user_has_no_transactions() -> None:
    response = _client(_sqlite_engine()).get("/transfers/suggestions")

    assert response.status_code == 200
    assert response.json() == {"suggestions": []}
