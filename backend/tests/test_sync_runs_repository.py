"""Tests for the sync run repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic (see ``.claude/rules/data-safety.md``).
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.db.base import Base
from traccio.db.repositories import count_recent_sync_runs, list_sync_runs, record_sync_run
from traccio.domain.enums import SyncRunOutcome, SyncTrigger
from traccio.domain.models import SyncRun

_USER_ID = uuid4()
_NOW = datetime(2026, 8, 24, 12, 0, 0, tzinfo=UTC)


def _engine() -> Engine:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _run(
    *,
    connection_id: UUID,
    trigger: SyncTrigger = SyncTrigger.BACKGROUND,
    outcome: SyncRunOutcome = SyncRunOutcome.SUCCESS,
    started_at: datetime = _NOW,
    accounts_synced: int = 1,
    transactions_synced: int = 3,
    error_reason: str | None = None,
) -> SyncRun:
    return SyncRun(
        user_id=_USER_ID,
        connection_id=connection_id,
        trigger=trigger,
        outcome=outcome,
        started_at=started_at,
        finished_at=started_at,
        accounts_synced=accounts_synced,
        transactions_synced=transactions_synced,
        error_reason=error_reason,
    )


def test_record_and_list_round_trips_every_field() -> None:
    engine = _engine()
    connection_id = uuid4()
    with Session(engine) as session:
        run = _run(
            connection_id=connection_id,
            trigger=SyncTrigger.USER_PRESENT,
            outcome=SyncRunOutcome.PROVIDER_FAILED,
            error_reason="provider_failed",
        )
        record_sync_run(session, sync_run=run)
        session.commit()

        found = list_sync_runs(session, user_id=_USER_ID)

        assert len(found) == 1
        stored = found[0]
        assert stored.connection_id == connection_id
        assert stored.trigger is SyncTrigger.USER_PRESENT
        assert stored.outcome is SyncRunOutcome.PROVIDER_FAILED
        assert stored.error_reason == "provider_failed"
        assert stored.accounts_synced == 1
        assert stored.transactions_synced == 3


def test_list_sync_runs_orders_most_recent_first_and_filters_by_connection() -> None:
    engine = _engine()
    connection_a = uuid4()
    connection_b = uuid4()
    with Session(engine) as session:
        record_sync_run(
            session, sync_run=_run(connection_id=connection_a, started_at=_NOW - timedelta(hours=2))
        )
        record_sync_run(session, sync_run=_run(connection_id=connection_a, started_at=_NOW))
        record_sync_run(session, sync_run=_run(connection_id=connection_b, started_at=_NOW))
        session.commit()

        all_runs = list_sync_runs(session, user_id=_USER_ID)
        assert len(all_runs) == 3
        assert all_runs[0].started_at >= all_runs[1].started_at >= all_runs[2].started_at

        only_a = list_sync_runs(session, user_id=_USER_ID, connection_id=connection_a)
        assert len(only_a) == 2
        assert all(r.connection_id == connection_a for r in only_a)


def test_list_sync_runs_excludes_other_users() -> None:
    engine = _engine()
    stranger_id = uuid4()
    with Session(engine) as session:
        record_sync_run(
            session,
            sync_run=SyncRun(
                user_id=stranger_id,
                connection_id=uuid4(),
                trigger=SyncTrigger.BACKGROUND,
                outcome=SyncRunOutcome.SUCCESS,
                started_at=_NOW,
                finished_at=_NOW,
            ),
        )
        session.commit()

        assert list_sync_runs(session, user_id=_USER_ID) == []


def test_count_recent_sync_runs_counts_only_within_the_window() -> None:
    engine = _engine()
    connection_id = uuid4()
    with Session(engine) as session:
        record_sync_run(
            session,
            sync_run=_run(connection_id=connection_id, started_at=_NOW - timedelta(hours=30)),
        )
        record_sync_run(
            session,
            sync_run=_run(connection_id=connection_id, started_at=_NOW - timedelta(hours=10)),
        )
        record_sync_run(
            session,
            sync_run=_run(connection_id=connection_id, started_at=_NOW - timedelta(hours=1)),
        )
        session.commit()

        count = count_recent_sync_runs(
            session, connection_id=connection_id, since=_NOW - timedelta(hours=24)
        )

        # Only the two runs within the last 24h; the 30h-old one is outside it.
        assert count == 2


def test_count_recent_sync_runs_counts_skips_too() -> None:
    """The budget must be verifiable, so a skip counts exactly like a success
    (docs/domain.md §Sync: "records what was attempted... and what failed")."""
    engine = _engine()
    connection_id = uuid4()
    with Session(engine) as session:
        record_sync_run(
            session,
            sync_run=_run(
                connection_id=connection_id, outcome=SyncRunOutcome.SKIPPED_BUDGET, started_at=_NOW
            ),
        )
        session.commit()

        assert (
            count_recent_sync_runs(
                session, connection_id=connection_id, since=_NOW - timedelta(hours=1)
            )
            == 1
        )


def test_count_recent_sync_runs_is_zero_for_an_unknown_connection() -> None:
    engine = _engine()
    with Session(engine) as session:
        assert (
            count_recent_sync_runs(session, connection_id=uuid4(), since=_NOW - timedelta(hours=24))
            == 0
        )
