"""Tests for the background sync scheduler (``services/scheduler.py``).

``run_due_syncs`` is synchronous and directly testable with an in-memory
SQLite engine and a local :class:`FakeProvider` — no asyncio needed. The two
``run_scheduler`` tests exercise the async loop itself, with
``asyncio.to_thread`` monkeypatched to run synchronously in-process: no real
thread, no real sleep, no network (matching the same discipline as every
other test file — ``.claude/rules/data-safety.md``, synthetic values only).
"""

import asyncio
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

import pytest
from cryptography.fernet import Fernet
from sqlalchemy import select
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _engine
from traccio.core.crypto import TokenCipher
from traccio.db.models import SyncRunRow
from traccio.db.repositories import activate_connection, create_connection, record_sync_run
from traccio.domain.enums import (
    AccountKind,
    ConnectionStatus,
    KeyStrategy,
    SyncRunOutcome,
    SyncTrigger,
    TransactionStatus,
)
from traccio.domain.models import Account, Connection, SyncRun, Transaction
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
from traccio.services import scheduler
from traccio.services.scheduler import run_due_syncs, run_scheduler

_USER_ID = uuid4()
_NOW = datetime(2026, 8, 24, 12, 0, 0, tzinfo=UTC)


class FakeProvider(BankProvider):
    """In-memory adapter. ``fetch_transactions`` fails only for credentials
    naming one of ``failing_credentials``, so a test can make one connection
    fail while another succeeds through the same shared provider instance —
    mirroring how one real adapter serves every connection."""

    def __init__(self, *, failing_credentials: frozenset[str] = frozenset()) -> None:
        self.failing_credentials = failing_credentials
        self.calls: list[str] = []

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
        self.calls.append(credentials)
        return [
            ProviderAccount(
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash=f"HASH-{credentials}",
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
        if credentials in self.failing_credentials:
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


def _cipher() -> TokenCipher:
    return TokenCipher(Fernet.generate_key().decode())


def _active_connection(
    session: Session,
    cipher: TokenCipher,
    *,
    credentials: str,
    expires_at: datetime | None = None,
) -> UUID:
    connection = Connection(
        user_id=_USER_ID,
        provider="fake",
        institution_name=f"Test Bank {credentials}",
        country="IT",
        status=ConnectionStatus.PENDING,
    )
    create_connection(session, connection=connection, auth_state=f"STATE-{credentials}")
    activate_connection(
        session,
        user_id=_USER_ID,
        connection_id=connection.id,
        encrypted_credentials=cipher.encrypt(credentials),
        expires_at=expires_at,
    )
    session.commit()
    return connection.id


def _default_kwargs(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = dict(
        now=_NOW,
        initial_history_days=730,
        sync_overlap_days=7,
        consent_warning_window_days=14,
        budget_per_day=4,
        min_interval_hours=6,
    )
    base.update(overrides)
    return base


def test_due_connection_is_synced_and_recorded_as_success() -> None:
    engine = _engine()
    cipher = _cipher()
    provider = FakeProvider()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, credentials="A")

        run_due_syncs(
            session, provider=provider, cipher=cipher, user_id=_USER_ID, **_default_kwargs()
        )

        runs = session.scalars(select(SyncRunRow)).all()
        assert len(runs) == 1
        run = runs[0]
        assert run.connection_id == connection_id
        assert run.trigger is SyncTrigger.BACKGROUND
        assert run.outcome is SyncRunOutcome.SUCCESS
        assert run.accounts_synced == 1
        assert run.transactions_synced == 1
        assert run.error_reason is None


def test_lapsed_consent_is_skipped_and_the_provider_is_never_called() -> None:
    engine = _engine()
    cipher = _cipher()
    provider = FakeProvider()
    with Session(engine) as session:
        _active_connection(
            session, cipher, credentials="A", expires_at=datetime(2020, 1, 1, tzinfo=UTC)
        )

        run_due_syncs(
            session, provider=provider, cipher=cipher, user_id=_USER_ID, **_default_kwargs()
        )

        runs = session.scalars(select(SyncRunRow)).all()
        assert len(runs) == 1
        assert runs[0].outcome is SyncRunOutcome.SKIPPED_CONSENT
        assert provider.calls == []


def test_budget_exhausted_is_skipped() -> None:
    engine = _engine()
    cipher = _cipher()
    provider = FakeProvider()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, credentials="A")
        # Pre-seed 4 runs in the last 24h — the default budget in _default_kwargs.
        for _ in range(4):
            record_sync_run(
                session,
                sync_run=SyncRun(
                    user_id=_USER_ID,
                    connection_id=connection_id,
                    trigger=SyncTrigger.BACKGROUND,
                    outcome=SyncRunOutcome.SUCCESS,
                    started_at=_NOW - timedelta(hours=1),
                    finished_at=_NOW - timedelta(hours=1),
                ),
            )
        session.commit()

        run_due_syncs(
            session, provider=provider, cipher=cipher, user_id=_USER_ID, **_default_kwargs()
        )

        runs = session.scalars(select(SyncRunRow)).all()
        assert len(runs) == 5  # the 4 seeded + this tick's skip
        assert runs[-1].outcome is SyncRunOutcome.SKIPPED_BUDGET
        assert provider.calls == []


def test_recently_synced_connection_is_skipped_for_the_interval() -> None:
    engine = _engine()
    cipher = _cipher()
    provider = FakeProvider()
    with Session(engine) as session:
        connection_id = _active_connection(session, cipher, credentials="A")
        # A successful sync 1h ago; the default min_interval_hours is 6.
        run_due_syncs(
            session,
            provider=provider,
            cipher=cipher,
            user_id=_USER_ID,
            **_default_kwargs(now=_NOW - timedelta(hours=1)),
        )
        assert provider.calls == ["A"]

        run_due_syncs(
            session, provider=provider, cipher=cipher, user_id=_USER_ID, **_default_kwargs()
        )

        runs = session.scalars(
            select(SyncRunRow).where(SyncRunRow.connection_id == connection_id)
        ).all()
        assert len(runs) == 2
        assert runs[-1].outcome is SyncRunOutcome.SKIPPED_INTERVAL
        # The provider was not called a second time.
        assert provider.calls == ["A"]


def test_one_connections_provider_failure_does_not_stop_the_others() -> None:
    engine = _engine()
    cipher = _cipher()
    provider = FakeProvider(failing_credentials=frozenset({"FAIL"}))
    with Session(engine) as session:
        failing_id = _active_connection(session, cipher, credentials="FAIL")
        healthy_id = _active_connection(session, cipher, credentials="OK")

        run_due_syncs(
            session, provider=provider, cipher=cipher, user_id=_USER_ID, **_default_kwargs()
        )

        runs = {r.connection_id: r for r in session.scalars(select(SyncRunRow)).all()}
        assert len(runs) == 2
        assert runs[failing_id].outcome is SyncRunOutcome.PROVIDER_FAILED
        assert runs[failing_id].error_reason == "provider fetch failed"
        assert runs[healthy_id].outcome is SyncRunOutcome.SUCCESS


def test_only_the_current_users_connections_are_considered() -> None:
    engine = _engine()
    cipher = _cipher()
    provider = FakeProvider()
    stranger_id = uuid4()
    with Session(engine) as session:
        connection = Connection(
            user_id=stranger_id,
            provider="fake",
            institution_name="Stranger Bank",
            country="IT",
            status=ConnectionStatus.PENDING,
        )
        create_connection(session, connection=connection, auth_state="STRANGER-STATE")
        activate_connection(
            session,
            user_id=stranger_id,
            connection_id=connection.id,
            encrypted_credentials=cipher.encrypt("STRANGER"),
            expires_at=None,
        )
        session.commit()

        run_due_syncs(
            session, provider=provider, cipher=cipher, user_id=_USER_ID, **_default_kwargs()
        )

        assert session.scalars(select(SyncRunRow)).all() == []
        assert provider.calls == []


@pytest.fixture
def _fake_to_thread(monkeypatch: pytest.MonkeyPatch) -> None:
    """Run ``asyncio.to_thread`` synchronously in-process: deterministic,
    no real thread, no real sleep."""

    async def _run_inline(func: Any, *args: Any, **kwargs: Any) -> Any:
        return func(*args, **kwargs)

    monkeypatch.setattr(asyncio, "to_thread", _run_inline)


def _scheduler_kwargs(*, stop_event: asyncio.Event, **overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = dict(
        provider=FakeProvider(),
        cipher=_cipher(),
        user_id=_USER_ID,
        interval_minutes=0,
        initial_history_days=730,
        sync_overlap_days=7,
        consent_warning_window_days=14,
        budget_per_day=4,
        min_interval_hours=6,
        stop_event=stop_event,
    )
    base.update(overrides)
    return base


async def test_run_scheduler_ticks_once_then_stops_cleanly(
    _fake_to_thread: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[None] = []
    stop_event = asyncio.Event()

    def fake_tick(**kwargs: Any) -> None:
        calls.append(None)
        stop_event.set()

    monkeypatch.setattr(scheduler, "_run_tick", fake_tick)

    await run_scheduler(**_scheduler_kwargs(stop_event=stop_event))

    assert len(calls) == 1


async def test_run_scheduler_survives_a_tick_that_raises(
    _fake_to_thread: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[None] = []
    stop_event = asyncio.Event()

    def flaky_tick(**kwargs: Any) -> None:
        calls.append(None)
        if len(calls) == 1:
            raise RuntimeError("boom")
        stop_event.set()

    monkeypatch.setattr(scheduler, "_run_tick", flaky_tick)

    await run_scheduler(**_scheduler_kwargs(stop_event=stop_event))

    # The first tick raised and was logged, not re-raised; the loop kept
    # going and reached a second tick.
    assert len(calls) == 2
