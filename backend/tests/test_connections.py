"""Tests for the bank connection (consent) endpoints.

The app is built via the factory; ``get_session`` binds a shared in-memory
SQLite engine, and the bank provider and token cipher are overridden with test
doubles, so the consent flow is exercised end to end (routing, persistence,
encryption) without a running PostgreSQL, a real bank, or a real key. Values are
synthetic (see ``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import uuid4

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.deps import get_bank_provider, get_token_cipher_dep
from traccio.api.main import create_app
from traccio.core.crypto import TokenCipher
from traccio.db.base import Base
from traccio.db.models import ConnectionRow
from traccio.db.session import get_session
from traccio.domain import Account, Transaction
from traccio.domain.enums import ConnectionStatus
from traccio.providers.base import (
    AuthorizationResult,
    AuthorizationStart,
    BankProvider,
    ProviderError,
    SyncContext,
)

_STATE = "STATE-XYZ-01"
_SESSION_ID = "11111111-2222-3333-4444-555555555555"
_EXPIRES_AT = datetime(2027, 2, 16, tzinfo=UTC)


class FakeProvider(BankProvider):
    """Adapter double returning canned consent DTOs.

    ``start_authorization`` always issues :data:`_STATE`; ``complete_authorization``
    returns :data:`_SESSION_ID` as the credential, or raises
    :class:`ProviderError` if the callback carried a bank error.
    """

    @property
    def name(self) -> str:
        return "enable_banking"

    def start_authorization(
        self, *, institution: str, country: str, redirect_url: str
    ) -> AuthorizationStart:
        return AuthorizationStart(
            authorization_url="https://sca.example/go", session_reference=_STATE
        )

    def complete_authorization(
        self, *, session_reference: str, callback_payload: dict[str, str]
    ) -> AuthorizationResult:
        if "error" in callback_payload:
            raise ProviderError("callback returned an error")
        return AuthorizationResult(
            credentials=_SESSION_ID, status=ConnectionStatus.ACTIVE, expires_at=_EXPIRES_AT
        )

    def list_accounts(self, *, credentials: str, context: SyncContext) -> list[Account]:
        raise NotImplementedError

    def fetch_transactions(
        self,
        *,
        credentials: str,
        account: Account,
        since: datetime,
        until: datetime | None,
        context: SyncContext,
    ) -> list[Transaction]:
        raise NotImplementedError


def _sqlite_engine() -> Engine:
    """Create a fresh in-memory SQLite engine sharing one connection."""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _client(engine: Engine, cipher: TokenCipher) -> TestClient:
    """Build a client bound to ``engine`` with the provider and cipher faked."""

    def override_get_session() -> Iterator[Session]:
        session = Session(engine)
        try:
            yield session
        finally:
            session.close()

    app = create_app()
    app.dependency_overrides[get_session] = override_get_session
    app.dependency_overrides[get_bank_provider] = lambda: FakeProvider()
    app.dependency_overrides[get_token_cipher_dep] = lambda: cipher
    return TestClient(app)


def _connections(engine: Engine) -> list[ConnectionRow]:
    with Session(engine) as session:
        return list(session.scalars(select(ConnectionRow)).all())


def test_start_connection_creates_pending_and_returns_url() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    response = client.post("/connections", json={"institution": "Test Bank 01", "country": "IT"})

    assert response.status_code == 200
    body = response.json()
    assert body["authorization_url"] == "https://sca.example/go"
    assert body["connection_id"]

    rows = _connections(engine)
    assert len(rows) == 1
    row = rows[0]
    assert row.status is ConnectionStatus.PENDING
    assert row.provider == "enable_banking"
    assert row.institution_name == "Test Bank 01"
    assert row.auth_state == _STATE
    assert row.encrypted_credentials is None


def test_callback_activates_connection_and_encrypts_the_credential() -> None:
    engine = _sqlite_engine()
    cipher = TokenCipher(Fernet.generate_key().decode())
    client = _client(engine, cipher)

    # Start, then complete via the callback the bank would redirect to.
    client.post("/connections", json={"institution": "Test Bank 01", "country": "IT"})
    response = client.get("/connections/callback", params={"code": "AUTH-CODE-01", "state": _STATE})

    assert response.status_code == 200

    row = _connections(engine)[0]
    assert row.status is ConnectionStatus.ACTIVE
    # SQLite returns naive datetimes even for timezone=True columns (PostgreSQL
    # preserves the tz); compare the wall-clock value regardless of tzinfo.
    assert row.expires_at is not None
    assert row.expires_at.replace(tzinfo=None) == _EXPIRES_AT.replace(tzinfo=None)
    assert row.auth_state is None
    # The credential is stored encrypted: the plaintext session id is absent,
    # and it decrypts back to the original (data-safety).
    assert row.encrypted_credentials is not None
    assert _SESSION_ID not in row.encrypted_credentials
    assert cipher.decrypt(row.encrypted_credentials) == _SESSION_ID


def test_callback_with_unknown_state_is_not_found() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    response = client.get(
        "/connections/callback", params={"code": "AUTH-CODE-01", "state": "NO-SUCH-STATE"}
    )

    assert response.status_code == 404


def test_callback_with_bank_error_is_rejected() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))
    client.post("/connections", json={"institution": "Test Bank 01", "country": "IT"})

    response = client.get(
        "/connections/callback",
        params={"state": _STATE, "error": "access_denied", "error_description": "secret-detail"},
    )

    assert response.status_code == 400
    assert "secret-detail" not in response.text
    # The connection stays pending; nothing was activated.
    assert _connections(engine)[0].status is ConnectionStatus.PENDING


def test_callback_does_not_match_another_users_pending_connection() -> None:
    engine = _sqlite_engine()
    # Insert a pending connection owned by a *different* user with our state.
    stranger_id = uuid4()
    with Session(engine) as session:
        session.add(
            ConnectionRow(
                id=uuid4(),
                user_id=stranger_id,
                provider="enable_banking",
                institution_name="STRANGER BANK",
                status=ConnectionStatus.PENDING,
                expires_at=None,
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
                encrypted_credentials=None,
                auth_state=_STATE,
            )
        )
        session.commit()

    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))
    response = client.get("/connections/callback", params={"code": "AUTH-CODE-01", "state": _STATE})

    # The dev user has no pending connection with this state; the stranger's is
    # invisible to the user-scoped lookup.
    assert response.status_code == 404
    assert _connections(engine)[0].status is ConnectionStatus.PENDING
