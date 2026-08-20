"""advances and advance_participants.

Adds the Advance write side (see ``docs/domain.md`` §Advance):

- ``advances`` — the user paid for others on one outgoing transaction and is owed
  money back. ``transaction_id`` is unique (a transaction has at most one
  advance). ``own_share`` is stored as a positive magnitude split into
  ``own_share_amount`` + ``own_share_currency``; ``receivable``/``outstanding``
  are derived, never stored.
- ``advance_participants`` — optional people who owe the user back, a free-text
  name plus an expected amount, one row per participant.

Both tables carry ``user_id`` (every query is scoped by it) and reference
``transactions``/``advances``. Portable across SQLite (local checks) and
PostgreSQL.

Revision ID: 9b3d1c7f2e64
Revises: 7c9e2a1b4d80
Create Date: 2026-08-20 22:30:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "9b3d1c7f2e64"
down_revision: str | Sequence[str] | None = "7c9e2a1b4d80"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "advances",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("transaction_id", sa.Uuid(), nullable=False),
        sa.Column("own_share_amount", sa.BigInteger(), nullable=False),
        sa.Column("own_share_currency", sa.String(length=3), nullable=False),
        sa.Column(
            "status",
            sa.Enum(
                "open",
                "settled",
                "written_off",
                name="advancestatus",
                native_enum=False,
            ),
            nullable=False,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["transaction_id"],
            ["transactions.id"],
            name=op.f("fk_advances_transaction_id_transactions"),
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name=op.f("fk_advances_user_id_users")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_advances")),
        sa.UniqueConstraint("transaction_id", name=op.f("uq_advances_transaction_id")),
    )
    op.create_index(op.f("ix_advances_user_id"), "advances", ["user_id"], unique=False)
    op.create_table(
        "advance_participants",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("advance_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("expected_amount", sa.BigInteger(), nullable=False),
        sa.Column("expected_currency", sa.String(length=3), nullable=False),
        sa.ForeignKeyConstraint(
            ["advance_id"],
            ["advances.id"],
            name=op.f("fk_advance_participants_advance_id_advances"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_advance_participants_user_id_users")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_advance_participants")),
    )
    op.create_index(
        op.f("ix_advance_participants_advance_id"),
        "advance_participants",
        ["advance_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_advance_participants_user_id"),
        "advance_participants",
        ["user_id"],
        unique=False,
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_advance_participants_user_id"), table_name="advance_participants")
    op.drop_index(op.f("ix_advance_participants_advance_id"), table_name="advance_participants")
    op.drop_table("advance_participants")
    op.drop_index(op.f("ix_advances_user_id"), table_name="advances")
    op.drop_table("advances")
