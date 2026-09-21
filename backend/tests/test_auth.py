"""Tests for the shared bearer token gate (ADR 0014, ``api/deps.py::require_api_token``).

Overrides ``get_settings`` per test rather than mutating the process-wide
``lru_cache``-d singleton (``core/config.py``), so these tests never affect
any other test's view of settings. ``GET /accounts`` stands in for "any
protected endpoint" — it needs only a database session and the fixed
``current_user_id``, no provider or cipher double.
"""

from collections.abc import Iterator

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _sqlite_engine
from tests.test_connections import FakeProvider
from traccio.api.deps import get_bank_provider, get_token_cipher_dep
from traccio.api.main import create_app
from traccio.core.config import Settings, get_settings
from traccio.core.crypto import TokenCipher
from traccio.db.session import get_session

_TOKEN = "TEST-TOKEN-01"


def _client(*, api_token: str | None) -> TestClient:
    """Build a client with ``api_token`` set, a fresh in-memory database.

    ``get_bank_provider``/``get_token_cipher_dep`` are faked too — most
    tests here hit ``/accounts``, which never resolves either dependency,
    but the callback test below does. Without a fake, that route's real
    dependencies raise unless a real Enable Banking application id and
    encryption key are configured — true by accident on a machine with a
    real ``.env``, false on a clean CI runner (the failure this guards
    against: it passed everywhere the author ran it, and nowhere else).
    """
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
    app.dependency_overrides[get_bank_provider] = lambda: FakeProvider()
    app.dependency_overrides[get_token_cipher_dep] = lambda: TokenCipher(
        Fernet.generate_key().decode()
    )
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
