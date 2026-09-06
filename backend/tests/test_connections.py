"""Tests for the bank connection (consent) endpoints.

The app is built via the factory; ``get_session`` binds a shared in-memory
SQLite engine, and the bank provider and token cipher are overridden with test
doubles, so the consent flow is exercised end to end (routing, persistence,
encryption) without a running PostgreSQL, a real bank, or a real key. Values are
synthetic (see ``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

import pytest
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine, select, update
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.deps import get_bank_provider, get_token_cipher_dep
from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.core.crypto import TokenCipher
from traccio.db.base import Base
from traccio.db.models import AccountRow, ConnectionRow, TransactionRow
from traccio.db.session import get_session
from traccio.domain import Account, Transaction
from traccio.domain.enums import AccountKind, ConnectionStatus, KeyStrategy, TransactionStatus
from traccio.domain.money import Money
from traccio.providers.base import (
    AuthorizationResult,
    AuthorizationStart,
    BankProvider,
    Institution,
    ProviderAccount,
    ProviderError,
    SyncContext,
)

_STATE = "STATE-XYZ-01"
_SESSION_ID = "11111111-2222-3333-4444-555555555555"
_EXPIRES_AT = datetime(2027, 2, 16, tzinfo=UTC)
# Synthetic accounts the fake adapter reports on sync (see data-safety rules).
_PROVIDER_ACCOUNTS = [
    ProviderAccount(
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash="HASH-CURR-01",
        name="TEST CURRENT 01",
    ),
    ProviderAccount(
        kind=AccountKind.CARD,
        currency="EUR",
        identification_hash="HASH-CARD-01",
        name="TEST CARD 01",
    ),
]
# Synthetic institutions the fake adapter reports for `GET /connections/institutions`
# (see data-safety rules).
_INSTITUTIONS = [
    Institution(name="Test Bank 01", country="IT", logo="https://logos.example.test/it/tb01/"),
    Institution(name="Test Bank 02", country="IT", logo=None),
]


class FakeProvider(BankProvider):
    """Adapter double returning canned consent DTOs.

    ``start_authorization`` always issues :data:`_STATE`; ``complete_authorization``
    returns :data:`_SESSION_ID` as the credential, or raises
    :class:`ProviderError` if the callback carried a bank error.

    Parameters
    ----------
    institutions_error : bool, optional
        When ``True``, ``list_institutions`` raises :class:`ProviderError`
        instead of returning :data:`_INSTITUTIONS` — exercises the
        endpoint's ``502`` path.
    """

    def __init__(self, *, institutions_error: bool = False) -> None:
        self.institutions_error = institutions_error

    @property
    def name(self) -> str:
        return "enable_banking"

    def list_institutions(self, *, country: str) -> list[Institution]:
        if self.institutions_error:
            raise ProviderError("provider institution lookup failed")
        return [institution for institution in _INSTITUTIONS if institution.country == country]

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

    def list_accounts(self, *, credentials: str, context: SyncContext) -> list[ProviderAccount]:
        # The endpoint must have decrypted the stored credential before calling us.
        assert credentials == _SESSION_ID
        return list(_PROVIDER_ACCOUNTS)

    def fetch_transactions(
        self,
        *,
        credentials: str,
        account: Account,
        since: datetime,
        until: datetime | None,
        context: SyncContext,
    ) -> list[Transaction]:
        assert credentials == _SESSION_ID
        # One booked transaction per account, with a stable key derived from the
        # account so a re-sync deduplicates rather than duplicating.
        return [
            Transaction(
                user_id=account.user_id,
                account_id=account.id,
                money=Money(amount=-1234, currency="EUR"),
                description="TEST MERCHANT 01",
                status=TransactionStatus.BOOKED,
                entry_reference=f"TX-{account.identification_hash}",
                stable_key=f"TX-{account.identification_hash}",
                key_strategy=KeyStrategy.ENTRY_REFERENCE,
            )
        ]


def _sqlite_engine() -> Engine:
    """Create a fresh in-memory SQLite engine sharing one connection."""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _client(
    engine: Engine, cipher: TokenCipher, *, provider: BankProvider | None = None
) -> TestClient:
    """Build a client bound to ``engine`` with the provider and cipher faked."""

    def override_get_session() -> Iterator[Session]:
        session = Session(engine)
        try:
            yield session
        finally:
            session.close()

    app = create_app()
    app.dependency_overrides[get_session] = override_get_session
    app.dependency_overrides[get_bank_provider] = lambda: provider or FakeProvider()
    app.dependency_overrides[get_token_cipher_dep] = lambda: cipher
    return TestClient(app)


def _connections(engine: Engine) -> list[ConnectionRow]:
    with Session(engine) as session:
        return list(session.scalars(select(ConnectionRow)).all())


def _accounts(engine: Engine) -> list[AccountRow]:
    with Session(engine) as session:
        return list(session.scalars(select(AccountRow)).all())


def _transactions(engine: Engine) -> list[TransactionRow]:
    with Session(engine) as session:
        return list(session.scalars(select(TransactionRow)).all())


def _activate_a_connection(client: TestClient) -> str:
    """Run the consent flow so a connection is active, and return its id."""
    start = client.post("/connections", json={"institution": "Test Bank 01", "country": "IT"})
    connection_id: str = start.json()["connection_id"]
    client.get("/connections/callback", params={"code": "AUTH-CODE-01", "state": _STATE})
    return connection_id


def test_list_institutions_returns_the_providers_institutions() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    response = client.get("/connections/institutions", params={"country": "IT"})

    assert response.status_code == 200
    assert response.json() == {
        "institutions": [
            {
                "name": "Test Bank 01",
                "country": "IT",
                "logo": "https://logos.example.test/it/tb01/",
            },
            {"name": "Test Bank 02", "country": "IT", "logo": None},
        ]
    }


def test_list_institutions_defaults_to_italy() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    response = client.get("/connections/institutions")

    assert response.status_code == 200
    assert len(response.json()["institutions"]) == 2


def test_list_institutions_filters_by_country() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    response = client.get("/connections/institutions", params={"country": "FR"})

    assert response.status_code == 200
    assert response.json() == {"institutions": []}


def test_list_institutions_wraps_a_provider_error_as_502() -> None:
    engine = _sqlite_engine()
    client = _client(
        engine,
        TokenCipher(Fernet.generate_key().decode()),
        provider=FakeProvider(institutions_error=True),
    )

    response = client.get("/connections/institutions", params={"country": "IT"})

    assert response.status_code == 502
    assert response.json()["detail"] == "provider institution lookup failed"


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
    assert row.country == "IT"
    assert row.auth_state == _STATE
    assert row.encrypted_credentials is None
    # No logo was sent, so none is stored.
    assert row.institution_logo is None


def test_start_connection_persists_the_supplied_logo_and_lists_it() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    client.post(
        "/connections",
        json={
            "institution": "Test Bank 01",
            "country": "IT",
            "logo": "https://logos.example.test/it/tb01/",
        },
    )
    client.get("/connections/callback", params={"code": "AUTH-CODE-01", "state": _STATE})

    assert _connections(engine)[0].institution_logo == "https://logos.example.test/it/tb01/"
    listed = client.get("/connections").json()["connections"][0]
    assert listed["institution_logo"] == "https://logos.example.test/it/tb01/"


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


def test_sync_persists_accounts_and_is_idempotent() -> None:
    engine = _sqlite_engine()
    cipher = TokenCipher(Fernet.generate_key().decode())
    client = _client(engine, cipher)
    connection_id = _activate_a_connection(client)

    # Before any sync, the connection carries no last_synced_at.
    before = client.get("/connections").json()["connections"][0]
    assert before["last_synced_at"] is None

    response = client.post(f"/connections/{connection_id}/sync")

    assert response.status_code == 200
    body = response.json()
    assert body["accounts_synced"] == 2
    assert body["transactions_synced"] == 2  # one per account, from the fake

    # A completed sync stamps the connection, for the client's "synced N ago".
    after = client.get("/connections").json()["connections"][0]
    assert after["last_synced_at"] is not None

    accounts = _accounts(engine)
    assert len(accounts) == 2
    assert {a.identification_hash for a in accounts} == {"HASH-CURR-01", "HASH-CARD-01"}
    # Persisted under this connection, and surfaced by GET /accounts.
    assert all(str(a.connection_id) == connection_id for a in accounts)
    assert len(client.get("/accounts").json()["accounts"]) == 2
    # Transactions landed too, each linked to a persisted account.
    txs = _transactions(engine)
    assert len(txs) == 2
    assert {t.account_id for t in txs} == {a.id for a in accounts}
    # Every row is stamped as observed by this sync (prune_stale_pending_transactions
    # ages a pending row off this, once syncs stop refreshing it).
    first_synced_at = {t.id: t.last_synced_at for t in txs}
    assert all(ts is not None for ts in first_synced_at.values())

    # Re-syncing updates in place rather than duplicating, for both resources.
    again = client.post(f"/connections/{connection_id}/sync")
    assert again.status_code == 200
    assert again.json() == {"accounts_synced": 2, "transactions_synced": 2}
    assert len(_accounts(engine)) == 2
    assert len(_transactions(engine)) == 2
    # The re-sync re-observed the same rows, so their stamp does not go backwards.
    for tx in _transactions(engine):
        assert tx.last_synced_at >= first_synced_at[tx.id]


def test_sync_unknown_connection_is_not_found() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    response = client.post(f"/connections/{uuid4()}/sync")

    assert response.status_code == 404


def test_sync_pending_connection_is_not_found() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))
    # Start (creates a pending connection) but never complete the callback.
    start = client.post("/connections", json={"institution": "Test Bank 01", "country": "IT"})
    connection_id = start.json()["connection_id"]

    response = client.post(f"/connections/{connection_id}/sync")

    # A pending connection has no usable credentials; it cannot sync.
    assert response.status_code == 404
    assert _accounts(engine) == []


def test_list_connections_returns_the_users_connections_without_secrets() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))
    connection_id = _activate_a_connection(client)

    response = client.get("/connections")

    assert response.status_code == 200
    connections = response.json()["connections"]
    assert len(connections) == 1
    body = connections[0]
    assert body["id"] == connection_id
    assert body["provider"] == "enable_banking"
    assert body["institution_name"] == "Test Bank 01"
    assert body["status"] == ConnectionStatus.ACTIVE.value
    assert body["expires_at"] is not None
    # consent_state is derived, not the raw status: _EXPIRES_AT is far enough in
    # the future (relative to the real clock the endpoint reads) to stay "active".
    assert body["consent_state"] == "active"
    assert isinstance(body["days_until_expiry"], int)
    # No secret material is ever projected (data-safety): neither the consent
    # secret nor the anti-CSRF state, and not even the field names.
    assert "encrypted_credentials" not in body
    assert "auth_state" not in body
    assert _SESSION_ID not in response.text
    assert _STATE not in response.text
    # The scheduler is off by default (Settings.background_sync_enabled),
    # so its two derived fields have nothing meaningful to report.
    assert body["background_sync_enabled"] is False
    assert body["sync_budget_remaining"] is None
    assert body["next_sync_at"] is None


def test_list_connections_exposes_scheduler_state_when_enabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(get_settings(), "background_sync_enabled", True)
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))
    _activate_a_connection(client)

    response = client.get("/connections")

    assert response.status_code == 200
    body = response.json()["connections"][0]
    assert body["background_sync_enabled"] is True
    # A freshly activated connection has no recorded runs: full budget, and
    # already due (never synced -> no interval to wait out), so no
    # meaningful "next sync at" to show.
    assert body["sync_budget_remaining"] == 4
    assert body["next_sync_at"] is None


def test_list_connections_excludes_other_users() -> None:
    engine = _sqlite_engine()
    stranger_id = uuid4()
    with Session(engine) as session:
        session.add(
            ConnectionRow(
                id=uuid4(),
                user_id=stranger_id,
                provider="enable_banking",
                institution_name="STRANGER BANK",
                status=ConnectionStatus.ACTIVE,
                expires_at=None,
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
                encrypted_credentials=None,
                auth_state=None,
            )
        )
        session.commit()

    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))
    response = client.get("/connections")

    assert response.status_code == 200
    # The stranger's connection is invisible to the user-scoped query.
    assert response.json() == {"connections": []}


def test_sync_refuses_a_lapsed_consent() -> None:
    """A stored ACTIVE connection past its expires_at is refused before the
    provider is ever called — the derived consent_state, not the stored status,
    gates the sync (see domain/consent.py)."""
    engine = _sqlite_engine()
    cipher = TokenCipher(Fernet.generate_key().decode())
    client = _client(engine, cipher)
    connection_id = _activate_a_connection(client)

    # Simulate a consent that lapsed since activation.
    with Session(engine) as session:
        session.execute(
            update(ConnectionRow)
            .where(ConnectionRow.id == UUID(connection_id))
            .values(expires_at=datetime(2020, 1, 1, tzinfo=UTC))
        )
        session.commit()

    response = client.post(f"/connections/{connection_id}/sync")

    assert response.status_code == 409
    assert response.json()["detail"] == "consent_expired"
    assert _accounts(engine) == []


def test_reauthorize_reissues_state_and_reactivates_the_same_connection() -> None:
    """Re-auth re-arms the existing row rather than creating a new connection,
    and accounts/history survive because identification_hash is stable across
    re-authorizations (docs/openbanking.md)."""
    engine = _sqlite_engine()
    cipher = TokenCipher(Fernet.generate_key().decode())
    client = _client(engine, cipher)
    connection_id = _activate_a_connection(client)
    client.post(f"/connections/{connection_id}/sync")
    assert len(_accounts(engine)) == 2

    response = client.post(f"/connections/{connection_id}/reauthorize")

    assert response.status_code == 200
    body = response.json()
    assert body["connection_id"] == connection_id
    assert body["authorization_url"] == "https://sca.example/go"
    row = _connections(engine)[0]
    assert row.auth_state == _STATE
    assert row.status is ConnectionStatus.ACTIVE  # unchanged until the callback lands

    # Completing the callback re-activates the SAME row — no second connection.
    callback = client.get("/connections/callback", params={"code": "AUTH-CODE-02", "state": _STATE})
    assert callback.status_code == 200
    assert len(_connections(engine)) == 1

    # A re-sync matches the same identification hashes and updates in place.
    again = client.post(f"/connections/{connection_id}/sync")
    assert again.status_code == 200
    assert len(_accounts(engine)) == 2


def test_reauthorize_unknown_connection_is_not_found() -> None:
    engine = _sqlite_engine()
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    response = client.post(f"/connections/{uuid4()}/reauthorize")

    assert response.status_code == 404


def test_reauthorize_without_a_stored_country_is_refused() -> None:
    """A connection created before `country` was persisted cannot be
    re-authorized in place; the client falls back to POST /connections."""
    engine = _sqlite_engine()
    connection_id = uuid4()
    with Session(engine) as session:
        session.add(
            ConnectionRow(
                id=connection_id,
                user_id=get_settings().dev_user_id,
                provider="enable_banking",
                institution_name="LEGACY BANK",
                country=None,
                status=ConnectionStatus.ACTIVE,
                expires_at=datetime(2020, 1, 1, tzinfo=UTC),
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
                encrypted_credentials=None,
                auth_state=None,
            )
        )
        session.commit()

    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))
    response = client.post(f"/connections/{connection_id}/reauthorize")

    assert response.status_code == 409
    assert response.json()["detail"] == "country_unknown"


def _seed_connection(
    engine: Engine,
    *,
    user_id: UUID,
    institution_name: str,
    country: str | None,
    institution_logo: str | None = None,
) -> UUID:
    """Insert one active connection row and return its id."""
    connection_id = uuid4()
    with Session(engine) as session:
        session.add(
            ConnectionRow(
                id=connection_id,
                user_id=user_id,
                provider="enable_banking",
                institution_name=institution_name,
                institution_logo=institution_logo,
                country=country,
                status=ConnectionStatus.ACTIVE,
                expires_at=datetime(2027, 1, 1, tzinfo=UTC),
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
                encrypted_credentials=None,
                auth_state=None,
            )
        )
        session.commit()
    return connection_id


def _connection(engine: Engine, connection_id: UUID) -> ConnectionRow:
    with Session(engine) as session:
        row = session.get(ConnectionRow, connection_id)
        assert row is not None
        return row


def test_backfill_logos_fills_a_connection_missing_one_and_is_idempotent() -> None:
    engine = _sqlite_engine()
    connection_id = _seed_connection(
        engine, user_id=get_settings().dev_user_id, institution_name="Test Bank 01", country="IT"
    )
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    first = client.post("/connections/backfill-logos")
    assert first.status_code == 200
    assert first.json() == {"updated": 1}
    row = _connection(engine, connection_id)
    assert row.institution_logo == "https://logos.example.test/it/tb01/"
    # An already-stored country is left as it is.
    assert row.country == "IT"

    # A second call changes nothing — the connection already has its logo.
    assert client.post("/connections/backfill-logos").json() == {"updated": 0}


def test_backfill_logos_falls_back_to_the_default_country_and_persists_it() -> None:
    engine = _sqlite_engine()
    # A connection from before the `country` column existed (migration
    # b8f3d2e7c1a4): NULL country and NULL logo, the same rows. The backfill
    # must still reach it, via Settings.default_institution_country, and write
    # the resolved country back so reauthorize stops 409-ing.
    connection_id = _seed_connection(
        engine, user_id=get_settings().dev_user_id, institution_name="Test Bank 01", country=None
    )
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    assert client.post("/connections/backfill-logos").json() == {"updated": 1}
    row = _connection(engine, connection_id)
    assert row.institution_logo == "https://logos.example.test/it/tb01/"
    assert row.country == "IT"


def test_backfill_logos_matches_institution_name_case_insensitively() -> None:
    engine = _sqlite_engine()
    connection_id = _seed_connection(
        engine,
        user_id=get_settings().dev_user_id,
        institution_name="  test bank 01 ",  # drifted case and whitespace
        country="IT",
    )
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    assert client.post("/connections/backfill-logos").json() == {"updated": 1}
    assert (
        _connection(engine, connection_id).institution_logo
        == "https://logos.example.test/it/tb01/"
    )


def test_backfill_logos_leaves_an_unmatched_institution_alone() -> None:
    engine = _sqlite_engine()
    # "Test Bank 02" exists in the provider list but with logo=None; the other
    # name matches no institution at all. Neither can be filled.
    logoless = _seed_connection(
        engine, user_id=get_settings().dev_user_id, institution_name="Test Bank 02", country="IT"
    )
    unknown = _seed_connection(
        engine, user_id=get_settings().dev_user_id, institution_name="NO SUCH BANK", country="IT"
    )
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    assert client.post("/connections/backfill-logos").json() == {"updated": 0}
    assert _connection(engine, logoless).institution_logo is None
    assert _connection(engine, unknown).institution_logo is None


def test_backfill_logos_wraps_a_provider_error_as_502() -> None:
    engine = _sqlite_engine()
    _seed_connection(
        engine, user_id=get_settings().dev_user_id, institution_name="Test Bank 01", country="IT"
    )
    client = _client(
        engine,
        TokenCipher(Fernet.generate_key().decode()),
        provider=FakeProvider(institutions_error=True),
    )

    assert client.post("/connections/backfill-logos").status_code == 502


def test_backfill_logos_excludes_other_users() -> None:
    engine = _sqlite_engine()
    stranger_connection = _seed_connection(
        engine, user_id=uuid4(), institution_name="Test Bank 01", country="IT"
    )
    client = _client(engine, TokenCipher(Fernet.generate_key().decode()))

    assert client.post("/connections/backfill-logos").json() == {"updated": 0}
    assert _connection(engine, stranger_connection).institution_logo is None
