"""Tests for the extracted sync orchestration service.

An in-memory SQLite engine backs persistence; a local :class:`FakeProvider`
stands in for the bank adapter. These exercise exactly the behavior
``api/routers/connections.py::sync_connection`` used to implement inline,
before it moved to :mod:`traccio.services.sync` — the router's own tests
(``tests/test_connections.py``) cover the HTTP-layer translation on top of
this. Values are synthetic (``.claude/rules/data-safety.md``).
"""

from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from cryptography.fernet import Fernet
from sqlalchemy import Engine, create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.core.crypto import TokenCipher
from traccio.db.base import Base
from traccio.db.models import AccountRow, ConnectionRow, TransactionRow
from traccio.db.repositories import activate_connection, create_connection
from traccio.domain.enums import AccountKind, ConnectionStatus, KeyStrategy, TransactionStatus
from traccio.domain.models import Account, Connection, Transaction
from traccio.domain.money import Money
from traccio.providers.base import (
    AuthorizationResult,
    AuthorizationStart,
    BankProvider,
    ProviderAccount,
    ProviderError,
    SyncContext,
)
from traccio.services.sync import (
    ConnectionNotFoundError,
    ConsentExpiredError,
    CredentialsUnavailableError,
    sync_connection,
)

_USER_ID = uuid4()
_NOW = datetime(2026, 8, 24, 12, 0, 0, tzinfo=UTC)
_SESSION_SECRET = "SESSION-SECRET-01"


class FakeProvider(BankProvider):
    """In-memory adapter returning one canned account and transaction.

    Optionally raises :class:`ProviderError` on ``fetch_transactions`` to
    exercise propagation.
    """

    def __init__(self, *, fail_on_fetch: bool = False) -> None:
        self.fail_on_fetch = fail_on_fetch
        self.last_context: SyncContext | None = None
        self.last_since: datetime | None = None

    @property
    def name(self) -> str:
        return "fake"

    def start_authorization(
        self, *, institution: str, country: str, redirect_url: str
    ) -> AuthorizationStart:
        raise NotImplementedError

    def complete_authorization(
        self, *, session_reference: str, callback_payload: Mapping[str, str]
    ) -> AuthorizationResult:
        raise NotImplementedError

    def list_accounts(self, *, credentials: str, context: SyncContext) -> list[ProviderAccount]:
        assert credentials == _SESSION_SECRET
        self.last_context = context
        return [
            ProviderAccount(
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash="HASH-CURR-01",
                name="TEST CURRENT 01",
            )
        ]

    def fetch_transactions(
        self,
        *,
        credentials: str,
        account: Account,
        since: datetime,
        until: datetime | None,
        context: SyncContext,
    ) -> list[Transaction]:
        self.last_since = since
        if self.fail_on_fetch:
            raise ProviderError("provider fetch failed")
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


def _engine() -> Engine:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    return engine


def _cipher() -> TokenCipher:
    return TokenCipher(Fernet.generate_key().decode())


def _active_connection(
    session: Session, cipher: TokenCipher, *, expires_at: datetime | None
) -> UUID:
    """Persist an active connection with an encrypted credential, and return its id."""
    connection = Connection(
        user_id=_USER_ID,
        provider="fake",
        institution_name="Test Bank 01",
        country="IT",
        status=ConnectionStatus.PENDING,
    )
    create_connection(session, connection=connection, auth_state="STATE-01")
    activate_connection(
        session,
        user_id=_USER_ID,
        connection_id=connection.id,
        encrypted_credentials=cipher.encrypt(_SESSION_SECRET),
        expires_at=expires_at,
    )
    session.commit()
    return connection.id


def test_sync_persists_accounts_and_transactions_and_stamps_last_synced_at() -> None:
    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)
        provider = FakeProvider()

        outcome = sync_connection(
            session,
            provider=provider,
            cipher=cipher,
            user_id=_USER_ID,
            connection_id=connection_id,
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=_NOW,
        )
        session.commit()

        assert outcome.accounts_synced == 1
        assert outcome.transactions_synced == 1
        assert provider.last_context == SyncContext(psu_present=True)

        accounts = session.scalars(select(AccountRow)).all()
        assert len(accounts) == 1
        transactions = session.scalars(select(TransactionRow)).all()
        assert len(transactions) == 1
        connection_row = session.scalars(
            select(ConnectionRow).where(ConnectionRow.id == connection_id)
        ).one()
        assert connection_row.last_synced_at == _NOW.replace(tzinfo=None)


def test_resync_updates_in_place_rather_than_duplicating() -> None:
    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)
        provider = FakeProvider()

        sync_connection(
            session,
            provider=provider,
            cipher=cipher,
            user_id=_USER_ID,
            connection_id=connection_id,
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=_NOW,
        )
        session.commit()

        sync_connection(
            session,
            provider=provider,
            cipher=cipher,
            user_id=_USER_ID,
            connection_id=connection_id,
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=_NOW,
        )
        session.commit()

        assert len(session.scalars(select(AccountRow)).all()) == 1
        assert len(session.scalars(select(TransactionRow)).all()) == 1


def test_first_sync_uses_the_greedy_initial_history_window() -> None:
    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)
        provider = FakeProvider()

        sync_connection(
            session,
            provider=provider,
            cipher=cipher,
            user_id=_USER_ID,
            connection_id=connection_id,
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=_NOW,
        )

        assert provider.last_since == _NOW - timedelta(days=730)


def test_later_sync_uses_last_synced_at_minus_the_overlap_not_the_initial_window() -> None:
    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)
        provider = FakeProvider()

        # First sync stamps last_synced_at = _NOW.
        sync_connection(
            session,
            provider=provider,
            cipher=cipher,
            user_id=_USER_ID,
            connection_id=connection_id,
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=_NOW,
        )
        session.commit()

        later = _NOW + timedelta(days=3)
        sync_connection(
            session,
            provider=provider,
            cipher=cipher,
            user_id=_USER_ID,
            connection_id=connection_id,
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=later,
        )

        # since = last_synced_at (_NOW) - 7 days, nowhere near the 730-day window.
        assert provider.last_since == _NOW - timedelta(days=7)


def test_unknown_connection_raises_connection_not_found() -> None:
    engine = _engine()
    with Session(engine) as session, pytest.raises(ConnectionNotFoundError):
        sync_connection(
            session,
            provider=FakeProvider(),
            cipher=_cipher(),
            user_id=_USER_ID,
            connection_id=uuid4(),
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=_NOW,
        )


def test_lapsed_consent_raises_consent_expired_before_the_provider_is_called() -> None:
    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(
            session, cipher, expires_at=datetime(2020, 1, 1, tzinfo=UTC)
        )
        provider = FakeProvider()

        with pytest.raises(ConsentExpiredError):
            sync_connection(
                session,
                provider=provider,
                cipher=cipher,
                user_id=_USER_ID,
                connection_id=connection_id,
                context=SyncContext(psu_present=True),
                initial_history_days=730,
                sync_overlap_days=7,
                consent_warning_window_days=14,
                now=_NOW,
            )

        # Refused before ever reaching the adapter.
        assert provider.last_context is None


def test_pending_connection_has_no_usable_credentials() -> None:
    engine = _engine()
    with Session(engine) as session:
        connection = Connection(
            user_id=_USER_ID,
            provider="fake",
            institution_name="Test Bank 01",
            country="IT",
            status=ConnectionStatus.PENDING,
        )
        create_connection(session, connection=connection, auth_state="STATE-01")
        session.commit()

        with pytest.raises(CredentialsUnavailableError):
            sync_connection(
                session,
                provider=FakeProvider(),
                cipher=_cipher(),
                user_id=_USER_ID,
                connection_id=connection.id,
                context=SyncContext(psu_present=True),
                initial_history_days=730,
                sync_overlap_days=7,
                consent_warning_window_days=14,
                now=_NOW,
            )


def test_provider_error_propagates_unchanged() -> None:
    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)

        with pytest.raises(ProviderError):
            sync_connection(
                session,
                provider=FakeProvider(fail_on_fetch=True),
                cipher=cipher,
                user_id=_USER_ID,
                connection_id=connection_id,
                context=SyncContext(psu_present=True),
                initial_history_days=730,
                sync_overlap_days=7,
                consent_warning_window_days=14,
                now=_NOW,
            )
