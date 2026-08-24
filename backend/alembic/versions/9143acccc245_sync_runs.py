"""sync runs.

Adds the ``SyncRun`` record (``docs/domain.md`` §Sync, ADR 0010): one row per
attempt to sync a connection, including a skip, so the per-connection
background fetch budget is verifiable rather than merely theoretical. Written
by ``services/sync.py`` and ``services/scheduler.py``; read by
``domain/sync_schedule.py::sync_decision``.

``(connection_id, started_at)`` carries an explicit composite index rather
than the per-column ``index=True`` convention used elsewhere — it is the one
query this table exists to serve fast, and it also covers a
``connection_id``-only lookup as its leftmost prefix, so no separate
single-column index is added. ``user_id`` keeps the usual per-table index
(``docs/architecture.md``: every table is scoped by ``user_id``).

Autogenerate also detected three pre-existing foreign-key constraints
(``transactions.confirmed_category_id`` / ``suggested_category_id`` /
``event_id`` -> their target tables) as "added" — these are not new. They are
the SQLite-skipped constraints from ``f2a6c9d4b7e1`` and ``c3f7a9e1d4b2``
(SQLite cannot ``ALTER TABLE ... ADD CONSTRAINT`` in place; the constraints
were deliberately added on PostgreSQL only, both migrations' docstrings
explain why). Autogenerate diffs the live SQLite dev database against the ORM
metadata, which always declares them, so it re-proposes them on every
autogenerate run against SQLite. Left out of this migration, same as before.

Revision ID: 9143acccc245
Revises: e7b2a4c8f915
Create Date: 2026-08-24 11:14:59.117560

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "9143acccc245"
down_revision: str | Sequence[str] | None = "e7b2a4c8f915"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "sync_runs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("connection_id", sa.Uuid(), nullable=False),
        sa.Column(
            "trigger",
            sa.Enum("user_present", "background", name="synctrigger", native_enum=False),
            nullable=False,
        ),
        sa.Column(
            "outcome",
            sa.Enum(
                "success",
                "provider_failed",
                "skipped_consent",
                "skipped_budget",
                "skipped_interval",
                name="syncrunoutcome",
                native_enum=False,
            ),
            nullable=False,
        ),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("accounts_synced", sa.Integer(), nullable=False),
        sa.Column("transactions_synced", sa.Integer(), nullable=False),
        sa.Column("error_reason", sa.String(length=255), nullable=True),
        sa.ForeignKeyConstraint(
            ["connection_id"],
            ["connections.id"],
            name=op.f("fk_sync_runs_connection_id_connections"),
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name=op.f("fk_sync_runs_user_id_users")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_sync_runs")),
    )
    op.create_index(
        "ix_sync_runs_connection_id_started_at",
        "sync_runs",
        ["connection_id", "started_at"],
        unique=False,
    )
    op.create_index(op.f("ix_sync_runs_user_id"), "sync_runs", ["user_id"], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_sync_runs_user_id"), table_name="sync_runs")
    op.drop_index("ix_sync_runs_connection_id_started_at", table_name="sync_runs")
    op.drop_table("sync_runs")
