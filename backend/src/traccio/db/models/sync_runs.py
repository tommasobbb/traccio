"""Persisted :class:`~traccio.domain.models.SyncRun`."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column
from traccio.domain.enums import SyncRunOutcome, SyncTrigger


class SyncRunRow(Base):
    """Persisted :class:`~traccio.domain.models.SyncRun`.

    Immutable, insert-only: a sync run is a historical record, not a mutable
    job (see the domain docstring). ``(connection_id, started_at)`` carries an
    explicit composite index — not the per-column ``index=True`` convention
    used elsewhere — because it is the one query this table exists to serve
    fast: "how many runs did this connection have in the last 24h"
    (:func:`~traccio.domain.sync_schedule.sync_decision`).

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    connection_id : UUID
        The connection this run attempted to sync (foreign key; see the
        composite index above — no separate single-column index is added, the
        composite already serves a connection_id-only lookup as its leftmost
        prefix).
    trigger : SyncTrigger
        Whether a user was waiting or the scheduler ran unattended.
    outcome : SyncRunOutcome
        What happened: synced, failed, or skipped (and why).
    started_at : datetime
        When the run began (timezone-aware, UTC).
    finished_at : datetime
        When the run concluded.
    accounts_synced : int
        How many accounts were listed and upserted.
    transactions_synced : int
        How many transactions were fetched and upserted, across all accounts.
    error_reason : str or None
        A stable, value-free reason code, set only for a non-``success``
        outcome. Never a provider message (``docs/engineering.md``).
    """

    __tablename__ = "sync_runs"
    __table_args__ = (
        Index("ix_sync_runs_connection_id_started_at", "connection_id", "started_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    connection_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("connections.id"))
    trigger: Mapped[SyncTrigger] = mapped_column(_enum_column(SyncTrigger))
    outcome: Mapped[SyncRunOutcome] = mapped_column(_enum_column(SyncRunOutcome))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    accounts_synced: Mapped[int] = mapped_column(Integer, default=0)
    transactions_synced: Mapped[int] = mapped_column(Integer, default=0)
    error_reason: Mapped[str | None] = mapped_column(String(255), nullable=True)
