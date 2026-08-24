"""Background sync scheduler: syncs due connections on a timer, within budget.

Single-process, single-user (Traccio is single-user until M4 — this loop
iterates one user's connections, not every user's). Started as an asyncio
task from ``api/main.py``'s lifespan; ``docs/architecture.md`` sanctions
exactly this ("Sync runs in a background task... no message queue, no
Celery, no Redis") and forbids a new top-level dependency for it.

Every tick: for each of the user's connections, ask
:func:`~traccio.domain.sync_schedule.sync_decision` whether it is due, and if
so run the exact same :func:`~traccio.services.sync.sync_connection` path a
user-triggered sync uses, with ``SyncContext(psu_present=False)``. Every
outcome — success, failure, or skip — is recorded as a
:class:`~traccio.domain.models.SyncRun` (ADR 0010), which is what makes the
next tick's budget check accurate.

A tick is one synchronous unit of work (:func:`run_due_syncs`), run via
``asyncio.to_thread`` because the database session underneath is sync
SQLAlchemy. The loop awaits a tick fully before waiting out the interval, so
two ticks never overlap — no separate "in-flight" guard is needed for that.
A connection whose processing raises anything unexpected is isolated with a
broad ``except Exception``, logged, and recorded as a failed run, so one bad
connection cannot stop the rest of the tick or a later one.

Assumes exactly one uvicorn worker process. With more than one, each process
would run its own independent loop and the per-connection budget would be
counted, and burned, once per process — a real limitation, not an oversight;
revisit with a database-level lock only if this ever needs more than one
process (YAGNI until then). See ``docs/decisions/0010-background-sync-scheduler.md``.
"""

import asyncio
import contextlib
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy.orm import Session

from traccio.core.crypto import TokenCipher
from traccio.core.logging import get_logger
from traccio.db.repositories import count_recent_sync_runs, list_connections, record_sync_run
from traccio.db.session import session_scope
from traccio.domain.consent import consent_state as derive_consent_state
from traccio.domain.enums import SyncRunOutcome, SyncTrigger
from traccio.domain.models import SyncRun
from traccio.domain.sync_schedule import sync_decision
from traccio.providers.base import BankProvider, ProviderError, SyncContext
from traccio.services.sync import SyncError, sync_connection

logger = get_logger(__name__)


def run_due_syncs(
    session: Session,
    *,
    provider: BankProvider,
    cipher: TokenCipher,
    user_id: UUID,
    now: datetime,
    initial_history_days: int,
    sync_overlap_days: int,
    consent_warning_window_days: int,
    budget_per_day: int,
    min_interval_hours: int,
) -> None:
    """Run one scheduler tick for ``user_id``: sync every due connection.

    Commits after each connection's outcome is recorded, so one connection's
    failure never rolls back another's already-recorded run from the same
    tick. Directly testable with no asyncio and a fake provider — see
    ``tests/test_scheduler.py``.

    Parameters
    ----------
    session : Session
        Active database session.
    provider : BankProvider
        The bank adapter to sync through.
    cipher : TokenCipher
        Decrypts each connection's stored consent secret.
    user_id : UUID
        The user whose connections to consider.
    now : datetime
        The current time, timezone-aware. Passed in rather than read
        internally so this stays testable with no clock; the same instant is
        used for every connection in the tick.
    initial_history_days : int
        Forwarded to :func:`~traccio.services.sync.sync_connection`.
    sync_overlap_days : int
        Forwarded to :func:`~traccio.services.sync.sync_connection`.
    consent_warning_window_days : int
        Forwarded to :func:`~traccio.domain.consent.consent_state` and
        :func:`~traccio.services.sync.sync_connection`.
    budget_per_day : int
        Forwarded to :func:`~traccio.domain.sync_schedule.sync_decision`
        (``Settings.background_sync_budget_per_day``).
    min_interval_hours : int
        Forwarded to :func:`~traccio.domain.sync_schedule.sync_decision`
        (``Settings.sync_min_interval_hours``).
    """
    for connection in list_connections(session, user_id):
        state = derive_consent_state(
            connection, now=now, warning_window_days=consent_warning_window_days
        )
        runs_last_24h = count_recent_sync_runs(
            session, connection_id=connection.id, since=now - timedelta(hours=24)
        )
        decision = sync_decision(
            consent_state=state,
            runs_last_24h=runs_last_24h,
            last_synced_at=connection.last_synced_at,
            now=now,
            budget_per_day=budget_per_day,
            min_interval_hours=min_interval_hours,
        )

        if not decision.due:
            assert decision.skip_reason is not None  # due=False always carries one
            record_sync_run(
                session,
                sync_run=SyncRun(
                    user_id=user_id,
                    connection_id=connection.id,
                    trigger=SyncTrigger.BACKGROUND,
                    outcome=decision.skip_reason,
                    started_at=now,
                    finished_at=now,
                ),
            )
            session.commit()
            continue

        try:
            outcome = sync_connection(
                session,
                provider=provider,
                cipher=cipher,
                user_id=user_id,
                connection_id=connection.id,
                context=SyncContext(psu_present=False),
                initial_history_days=initial_history_days,
                sync_overlap_days=sync_overlap_days,
                consent_warning_window_days=consent_warning_window_days,
                now=now,
            )
        except Exception as exc:
            # SyncError/ProviderError messages are stable and value-free by
            # contract (providers/base.py, services/sync.py); anything else
            # is an unexpected bug, logged by type only, never str(exc).
            reason = str(exc) if isinstance(exc, SyncError | ProviderError) else type(exc).__name__
            logger.warning("scheduler.sync_failed", connection_id=str(connection.id), reason=reason)
            record_sync_run(
                session,
                sync_run=SyncRun(
                    user_id=user_id,
                    connection_id=connection.id,
                    trigger=SyncTrigger.BACKGROUND,
                    outcome=SyncRunOutcome.PROVIDER_FAILED,
                    started_at=now,
                    finished_at=now,
                    error_reason=reason,
                ),
            )
            session.commit()
            continue

        record_sync_run(
            session,
            sync_run=SyncRun(
                user_id=user_id,
                connection_id=connection.id,
                trigger=SyncTrigger.BACKGROUND,
                outcome=SyncRunOutcome.SUCCESS,
                started_at=now,
                finished_at=now,
                accounts_synced=outcome.accounts_synced,
                transactions_synced=outcome.transactions_synced,
            ),
        )
        session.commit()
        logger.info(
            "scheduler.sync_succeeded",
            connection_id=str(connection.id),
            accounts_synced=outcome.accounts_synced,
            transactions_synced=outcome.transactions_synced,
        )


def _run_tick(
    *,
    provider: BankProvider,
    cipher: TokenCipher,
    user_id: UUID,
    initial_history_days: int,
    sync_overlap_days: int,
    consent_warning_window_days: int,
    budget_per_day: int,
    min_interval_hours: int,
) -> None:
    """Open a session for one tick and run :func:`run_due_syncs` in it."""
    with session_scope() as session:
        run_due_syncs(
            session,
            provider=provider,
            cipher=cipher,
            user_id=user_id,
            now=datetime.now(UTC),
            initial_history_days=initial_history_days,
            sync_overlap_days=sync_overlap_days,
            consent_warning_window_days=consent_warning_window_days,
            budget_per_day=budget_per_day,
            min_interval_hours=min_interval_hours,
        )


async def run_scheduler(
    *,
    provider: BankProvider,
    cipher: TokenCipher,
    user_id: UUID,
    interval_minutes: int,
    initial_history_days: int,
    sync_overlap_days: int,
    consent_warning_window_days: int,
    budget_per_day: int,
    min_interval_hours: int,
    stop_event: asyncio.Event,
) -> None:
    """Run scheduler ticks until ``stop_event`` is set.

    Ticks immediately on start (so a freshly started backend syncs promptly
    rather than waiting up to a full interval), then every
    ``interval_minutes`` after that. Runs each tick in a worker thread
    (``asyncio.to_thread``) since the database session underneath is sync
    SQLAlchemy — never call this on the event loop thread's session directly.
    A tick that raises (something ``run_due_syncs``'s own per-connection
    isolation did not catch — a truly unexpected failure) is logged and does
    not stop the loop.

    Parameters
    ----------
    provider : BankProvider
        The bank adapter to sync through, held for the scheduler's whole
        lifetime (``api/main.py``'s lifespan owns closing its client).
    cipher : TokenCipher
        Decrypts each connection's stored consent secret.
    user_id : UUID
        The user whose connections to consider.
    interval_minutes : int
        Minutes between the end of one tick and the start of the next
        (``Settings.background_sync_interval_minutes``).
    initial_history_days, sync_overlap_days, consent_warning_window_days,
    budget_per_day, min_interval_hours : int
        Forwarded to :func:`run_due_syncs` on every tick.
    stop_event : asyncio.Event
        Set by the caller to end the loop gracefully (``api/main.py``'s
        lifespan sets it on shutdown and awaits this coroutine's task).
    """
    while not stop_event.is_set():
        try:
            await asyncio.to_thread(
                _run_tick,
                provider=provider,
                cipher=cipher,
                user_id=user_id,
                initial_history_days=initial_history_days,
                sync_overlap_days=sync_overlap_days,
                consent_warning_window_days=consent_warning_window_days,
                budget_per_day=budget_per_day,
                min_interval_hours=min_interval_hours,
            )
        except Exception:
            logger.exception("scheduler.tick_failed")

        # TimeoutError is the normal case: the interval elapsed with no stop
        # request, so loop again.
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop_event.wait(), timeout=interval_minutes * 60)
