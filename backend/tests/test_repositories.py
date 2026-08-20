"""Tests for the account write-path and credential-read repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic and the "credential" is an opaque placeholder, never a real
token (see ``.claude/rules/data-safety.md``).
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy import Engine, create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.db.base import Base
from traccio.db.models import AccountRow, ConnectionRow
from traccio.db.repositories import get_connection_credentials, upsert_account
from traccio.domain import Account
from traccio.domain.enums import AccountKind, ConnectionStatus


def _engine() -> Engine:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _account(
    *,
    user_id: UUID,
    connection_id: UUID,
    identification_hash: str = "HASH-01",
    name: str = "TEST CURRENT 01",
) -> Account:
    return Account(
        user_id=user_id,
        connection_id=connection_id,
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash=identification_hash,
        name=name,
    )


def _add_connection(
    engine: Engine,
    *,
    user_id: UUID,
    connection_id: UUID,
    status: ConnectionStatus,
    credentials: str | None,
) -> None:
    with Session(engine) as session:
        session.add(
            ConnectionRow(
                id=connection_id,
                user_id=user_id,
                provider="enable_banking",
                institution_name="TEST BANK 01",
                status=status,
                expires_at=None,
                created_at=datetime.now(UTC),
                encrypted_credentials=credentials,
                auth_state=None,
            )
        )
        session.commit()


def test_upsert_account_inserts_a_new_account() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        result = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        session.commit()
        inserted_id = result.id

    with Session(engine) as session:
        rows = list(session.scalars(select(AccountRow)).all())
    assert len(rows) == 1
    assert rows[0].id == inserted_id
    assert rows[0].identification_hash == "HASH-01"


def test_upsert_account_updates_in_place_without_duplicating() -> None:
    engine = _engine()
    user_id, first_conn, second_conn = uuid4(), uuid4(), uuid4()

    with Session(engine) as session:
        upsert_account(
            session, account=_account(user_id=user_id, connection_id=first_conn, name="OLD NAME")
        )
        session.commit()
    with Session(engine) as session:
        before = session.scalars(select(AccountRow)).one()
        original_id, original_created = before.id, before.created_at

    # The same account (same identification_hash) re-exposed via a new consent.
    with Session(engine) as session:
        upsert_account(
            session, account=_account(user_id=user_id, connection_id=second_conn, name="NEW NAME")
        )
        session.commit()

    with Session(engine) as session:
        rows = list(session.scalars(select(AccountRow)).all())
    assert len(rows) == 1
    row = rows[0]
    # Identity and creation time are preserved; the mutable fields are refreshed.
    assert row.id == original_id
    assert row.created_at == original_created
    assert row.connection_id == second_conn
    assert row.name == "NEW NAME"


def test_upsert_account_separates_users_with_the_same_hash() -> None:
    engine = _engine()
    shared_hash = "HASH-SHARED"
    user_a, user_b = uuid4(), uuid4()

    with Session(engine) as session:
        upsert_account(
            session,
            account=_account(
                user_id=user_a, connection_id=uuid4(), identification_hash=shared_hash
            ),
        )
        upsert_account(
            session,
            account=_account(
                user_id=user_b, connection_id=uuid4(), identification_hash=shared_hash
            ),
        )
        session.commit()

    with Session(engine) as session:
        rows = list(session.scalars(select(AccountRow)).all())
    # The uniqueness is (user_id, identification_hash): two users, two rows.
    assert len(rows) == 2
    assert {r.user_id for r in rows} == {user_a, user_b}


def test_get_connection_credentials_returns_active_ciphertext() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=user_id,
        connection_id=connection_id,
        status=ConnectionStatus.ACTIVE,
        credentials="CIPHERTEXT-01",
    )

    with Session(engine) as session:
        creds = get_connection_credentials(session, user_id=user_id, connection_id=connection_id)

    assert creds == "CIPHERTEXT-01"


def test_get_connection_credentials_ignores_pending_connection() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=user_id,
        connection_id=connection_id,
        status=ConnectionStatus.PENDING,
        credentials=None,
    )

    with Session(engine) as session:
        creds = get_connection_credentials(session, user_id=user_id, connection_id=connection_id)

    assert creds is None


def test_get_connection_credentials_is_user_scoped() -> None:
    engine = _engine()
    stranger_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=stranger_id,
        connection_id=connection_id,
        status=ConnectionStatus.ACTIVE,
        credentials="CIPHERTEXT-01",
    )

    with Session(engine) as session:
        creds = get_connection_credentials(session, user_id=uuid4(), connection_id=connection_id)

    # Another user's active connection is invisible to the scoped lookup.
    assert creds is None
