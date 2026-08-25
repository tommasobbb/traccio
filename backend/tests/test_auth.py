"""Tests for the shared bearer token gate (ADR 0014, ``api/deps.py::require_api_token``).

Overrides ``get_settings`` per test rather than mutating the process-wide
``lru_cache``-d singleton (``core/config.py``), so these tests never affect
any other test's view of settings. ``GET /accounts`` stands in for "any
protected endpoint" — it needs only a database session and the fixed
``current_user_id``, no provider or cipher double.
"""

from collections.abc import Iterator

from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.main import create_app
from traccio.core.config import Settings, get_settings
from traccio.db.base import Base
from traccio.db.session import get_session

_TOKEN = "TEST-TOKEN-01"


def _sqlite_engine() -> Engine:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    return engine


def _client(*, api_token: str | None) -> TestClient:
    """Build a client with ``api_token`` set, a fresh in-memory database."""
    engine = _sqlite_engine()

    def override_get_session() -> Iterator[Session]:
        session = Session(engine)
        try:
            yield session
        finally:
            session.close()

    app = create_app()
    app.dependency_overrides[get_session] = override_get_session
    app.dependency_overrides[get_settings] = lambda: Settings(api_token=api_token)
    return TestClient(app)


def test_protected_endpoint_without_header_is_unauthorized() -> None:
    client = _client(api_token=_TOKEN)

    response = client.get("/accounts")

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_protected_endpoint_with_wrong_token_is_unauthorized() -> None:
    client = _client(api_token=_TOKEN)

    response = client.get("/accounts", headers={"Authorization": "Bearer wrong-token"})

    assert response.status_code == 401


def test_protected_endpoint_with_malformed_header_is_unauthorized() -> None:
    client = _client(api_token=_TOKEN)

    response = client.get("/accounts", headers={"Authorization": _TOKEN})

    assert response.status_code == 401


def test_protected_endpoint_with_correct_token_is_authorized() -> None:
    client = _client(api_token=_TOKEN)

    response = client.get("/accounts", headers={"Authorization": f"Bearer {_TOKEN}"})

    assert response.status_code == 200


def test_protected_endpoint_is_open_when_api_token_is_unset() -> None:
    """The default: no ``.env``, no gate — every existing test relies on this."""
    client = _client(api_token=None)

    response = client.get("/accounts")

    assert response.status_code == 200


def test_health_is_reachable_without_a_token_even_when_one_is_configured() -> None:
    client = _client(api_token=_TOKEN)

    response = client.get("/health")

    assert response.status_code == 200


def test_connections_callback_is_reachable_without_a_token_even_when_one_is_configured() -> None:
    """The bank's browser redirect cannot carry a bearer header.

    An unknown ``state`` reaches the real handler and is rejected as 404 —
    proof the request got past the token gate rather than being stopped at
    401, without needing a full consent flow's fixtures.
    """
    client = _client(api_token=_TOKEN)

    response = client.get("/connections/callback", params={"state": "unknown-state"})

    assert response.status_code == 404
