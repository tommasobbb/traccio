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
from traccio.db.repositories import (
    activate_connection,
    create_category,
    create_connection,
    create_rule,
    set_confirmed_category,
)
from traccio.domain.enums import (
    AccountKind,
    ConnectionStatus,
    KeyStrategy,
    RuleMatchKind,
    TransactionStatus,
)
from traccio.domain.models import Account, Category, Connection, Rule, Transaction
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

    def list_institutions(self, *, country: str) -> list[Institution]:
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


def test_sync_never_touches_a_manual_account_or_its_transactions() -> None:
    """A manual account (ADR 0020) is invisible to sync.

    Sync iterates only the provider's own accounts, and ``upsert_account``
    matches on ``(user_id, identification_hash)`` where a manual account's
    hash is ``NULL`` (``NULL != NULL``). So a manual account and its
    hand-entered rows survive a sync completely unchanged.
    """
    engine = _engine()
    cipher = _cipher()
    manual_account_id = uuid4()
    manual_tx_id = uuid4()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)
        session.add(
            AccountRow(
                id=manual_account_id,
                user_id=_USER_ID,
                connection_id=None,
                kind=AccountKind.CASH,
                currency="EUR",
                identification_hash=None,
                name=None,
                alias="Contanti",
                created_at=_NOW,
            )
        )
        session.add(
            TransactionRow(
                id=manual_tx_id,
                user_id=_USER_ID,
                account_id=manual_account_id,
                amount=-500,
                currency="EUR",
                booked_at=None,
                value_date=_NOW,
                description="TEST CASH 01",
                status=TransactionStatus.BOOKED,
                stable_key=str(manual_tx_id),
                key_strategy=KeyStrategy.MANUAL,
                last_synced_at=None,
            )
        )
        session.commit()

        sync_connection(
            session,
            provider=FakeProvider(),
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

        # The synced account/transaction landed alongside, but the manual ones
        # are byte-for-byte what they were.
        manual_account = session.scalars(
            select(AccountRow).where(AccountRow.id == manual_account_id)
        ).one()
        assert manual_account.connection_id is None
        assert manual_account.identification_hash is None
        assert manual_account.alias == "Contanti"

        manual_tx = session.scalars(
            select(TransactionRow).where(TransactionRow.id == manual_tx_id)
        ).one()
        assert manual_tx.last_synced_at is None
        assert manual_tx.key_strategy is KeyStrategy.MANUAL
        assert manual_tx.amount == -500

        assert len(session.scalars(select(AccountRow)).all()) == 2


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


def test_sync_suggests_a_category_for_a_newly_synced_transaction() -> None:
    """A rule matching the fake's "TEST MERCHANT 01" description suggests a
    category with no explicit POST /rules/apply call — detection runs as
    part of the sync pipeline (docs/architecture.md)."""
    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)
        category = create_category(session, category=Category(user_id=_USER_ID, name="Groceries"))
        create_rule(
            session,
            rule=Rule(
                user_id=_USER_ID,
                category_id=category.id,
                match_kind=RuleMatchKind.CONTAINS,
                pattern="TEST MERCHANT",
            ),
        )
        session.commit()

        sync_connection(
            session,
            provider=FakeProvider(),
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

        row = session.scalars(select(TransactionRow)).one()
        assert row.suggested_category_id == category.id
        assert row.confirmed_category_id is None


def test_sync_never_overwrites_a_confirmed_category() -> None:
    """confirmed_category_id is set only by explicit user action
    (docs/domain.md §Category) — a re-sync that re-observes and re-suggests
    for the same row must never touch it."""
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

        transaction_id = session.scalars(select(TransactionRow.id)).one()
        category = create_category(session, category=Category(user_id=_USER_ID, name="Groceries"))
        set_confirmed_category(
            session, user_id=_USER_ID, transaction_id=transaction_id, category_id=category.id
        )
        create_rule(
            session,
            rule=Rule(
                user_id=_USER_ID,
                category_id=category.id,
                match_kind=RuleMatchKind.CONTAINS,
                pattern="TEST MERCHANT",
            ),
        )
        session.commit()

        # A later sync re-observes the same (now terminal/booked) transaction
        # and re-runs detection over it.
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
            now=_NOW + timedelta(hours=1),
        )
        session.commit()

        row = session.scalars(
            select(TransactionRow).where(TransactionRow.id == transaction_id)
        ).one()
        assert row.confirmed_category_id == category.id
        assert row.suggested_category_id == category.id


def test_sync_succeeds_even_if_detection_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    """Detection failures do not fail the sync (docs/architecture.md)."""
    import traccio.services.sync as sync_module

    def boom(*args: object, **kwargs: object) -> None:
        raise RuntimeError("boom")

    monkeypatch.setattr(sync_module, "suggest_categories", boom)

    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)
        category = create_category(session, category=Category(user_id=_USER_ID, name="Groceries"))
        create_rule(
            session,
            rule=Rule(
                user_id=_USER_ID,
                category_id=category.id,
                match_kind=RuleMatchKind.CONTAINS,
                pattern="TEST MERCHANT",
            ),
        )
        session.commit()

        outcome = sync_connection(
            session,
            provider=FakeProvider(),
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

        assert outcome.transactions_synced == 1
        row = session.scalars(select(TransactionRow)).one()
        assert row.suggested_category_id is None


def test_sync_with_no_upserted_transactions_skips_detection_entirely(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No rules are even read when a sync upserts nothing."""
    import traccio.services.sync as sync_module

    calls: list[None] = []

    def fake_list_rules(*args: object, **kwargs: object) -> list[Rule]:
        calls.append(None)
        return []

    monkeypatch.setattr(sync_module, "list_rules", fake_list_rules)

    class EmptyProvider(FakeProvider):
        def fetch_transactions(
            self,
            *,
            credentials: str,
            account: Account,
            since: datetime,
            until: datetime | None,
            context: SyncContext,
        ) -> list[Transaction]:
            return []

    engine = _engine()
    cipher = _cipher()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, expires_at=None)

        sync_connection(
            session,
            provider=EmptyProvider(),
            cipher=cipher,
            user_id=_USER_ID,
            connection_id=connection_id,
            context=SyncContext(psu_present=True),
            initial_history_days=730,
            sync_overlap_days=7,
            consent_warning_window_days=14,
            now=_NOW,
        )

        assert calls == []
