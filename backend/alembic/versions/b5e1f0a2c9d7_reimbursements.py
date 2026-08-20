"""reimbursements.

Adds the Reimbursement write side (see ``docs/domain.md`` §Reimbursement):

- ``reimbursements`` — money paid back against one advance. Either links a real
  incoming transaction (``transaction_id`` set, whose ``role`` becomes
  ``reimbursement``) or is a manual cash entry (``transaction_id`` NULL).
  ``amount`` is a positive magnitude split into ``amount`` + ``currency``. The
  advance's ``outstanding`` and derived status follow from the sum of these,
  never stored on the advance (see ADR 0004).

The table carries ``user_id`` (every query is scoped by it) and references
``advances``/``transactions``. Portable across SQLite (local checks) and
PostgreSQL.

Revision ID: b5e1f0a2c9d7
Revises: 9b3d1c7f2e64
Create Date: 2026-08-21 09:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b5e1f0a2c9d7"
down_revision: str | Sequence[str] | None = "9b3d1c7f2e64"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "reimbursements",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("advance_id", sa.Uuid(), nullable=False),
        sa.Column("amount", sa.BigInteger(), nullable=False),
        sa.Column("currency", sa.String(length=3), nullable=False),
        sa.Column("transaction_id", sa.Uuid(), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["advance_id"],
            ["advances.id"],
            name=op.f("fk_reimbursements_advance_id_advances"),
        ),
        sa.ForeignKeyConstraint(
            ["transaction_id"],
            ["transactions.id"],
            name=op.f("fk_reimbursements_transaction_id_transactions"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_reimbursements_user_id_users")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_reimbursements")),
    )
    op.create_index(
        op.f("ix_reimbursements_advance_id"), "reimbursements", ["advance_id"], unique=False
    )
    op.create_index(op.f("ix_reimbursements_user_id"), "reimbursements", ["user_id"], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_reimbursements_user_id"), table_name="reimbursements")
    op.drop_index(op.f("ix_reimbursements_advance_id"), table_name="reimbursements")
    op.drop_table("reimbursements")
