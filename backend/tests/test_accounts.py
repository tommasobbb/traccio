"""Tests for ``GET /accounts``.

The app is built via the factory and its ``get_session`` dependency is
overridden to a shared in-memory SQLite engine, so the endpoint is exercised
end to end (routing, response schema, repository query) without a running
PostgreSQL. Values are synthetic (see ``.claude/rules/data-safety.md``).
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
from traccio.db.models import AccountRow
from traccio.db.session import get_session
from traccio.domain.enums import AccountKind


def _account(
    user_id: UUID, identification_hash: str, name: str, created_at: datetime
) -> AccountRow:
    """Build a synthetic account row for ``user_id``."""
    return AccountRow(
        id=uuid4(),
        user_id=user_id,
        connection_id=uuid4(),
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash=identification_hash,
        name=name,
        created_at=created_at,
    )


def _client(engine: Engine) -> TestClient:
    """Build a client whose sessions come from ``engine``."""

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
    """Create a fresh in-memory SQLite engine sharing one connection."""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def test_accounts_returns_only_current_users_accounts_oldest_first() -> None:
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _account(dev_user_id, "h-2", "TEST B", datetime(2026, 2, 1, tzinfo=UTC)),
                _account(dev_user_id, "h-1", "TEST A", datetime(2026, 1, 1, tzinfo=UTC)),
                _account(stranger_id, "h-x", "STRANGER", datetime(2026, 1, 1, tzinfo=UTC)),
            ]
        )
        session.commit()

    response = _client(engine).get("/accounts")

    assert response.status_code == 200
    accounts = response.json()["accounts"]
    # Only the dev user's accounts, oldest first; the stranger's is excluded.
    assert [a["name"] for a in accounts] == ["TEST A", "TEST B"]


def test_accounts_empty_when_user_has_none() -> None:
    response = _client(_sqlite_engine()).get("/accounts")

    assert response.status_code == 200
    assert response.json() == {"accounts": []}
