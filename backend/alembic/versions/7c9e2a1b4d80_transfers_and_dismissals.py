"""transfers and transfer_dismissals.

Adds the write side of transfer detection (see ``docs/domain.md`` §Transfer):

- ``transfers`` — a confirmed link between two of the user's transactions (the
  outgoing/negative and incoming/positive legs). Created only by an explicit user
  action, which also sets both legs' ``role`` to ``transfer``. Unique on
  ``(user_id, outgoing_transaction_id, incoming_transaction_id)``.
- ``transfer_dismissals`` — a pair the user rejected as a transfer, stored in
  canonical sorted order so it is order-independent and unique per user, so
  detection does not propose it again.

Both tables carry ``user_id`` (every query is scoped by it) and reference
``transactions``. Portable across SQLite (local checks) and PostgreSQL.

Revision ID: 7c9e2a1b4d80
Revises: 3a7aa15d883f
Create Date: 2026-08-20 21:15:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "7c9e2a1b4d80"
down_revision: str | Sequence[str] | None = "3a7aa15d883f"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "transfers",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("outgoing_transaction_id", sa.Uuid(), nullable=False),
        sa.Column("incoming_transaction_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["incoming_transaction_id"],
            ["transactions.id"],
            name=op.f("fk_transfers_incoming_transaction_id_transactions"),
        ),
        sa.ForeignKeyConstraint(
            ["outgoing_transaction_id"],
            ["transactions.id"],
            name=op.f("fk_transfers_outgoing_transaction_id_transactions"),
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name=op.f("fk_transfers_user_id_users")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_transfers")),
        sa.UniqueConstraint(
            "user_id",
            "outgoing_transaction_id",
            "incoming_transaction_id",
            name=op.f("uq_transfers_user_id"),
        ),
    )
    op.create_index(op.f("ix_transfers_user_id"), "transfers", ["user_id"], unique=False)
    op.create_table(
        "transfer_dismissals",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("transaction_id_a", sa.Uuid(), nullable=False),
        sa.Column("transaction_id_b", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["transaction_id_a"],
            ["transactions.id"],
            name=op.f("fk_transfer_dismissals_transaction_id_a_transactions"),
        ),
        sa.ForeignKeyConstraint(
            ["transaction_id_b"],
            ["transactions.id"],
            name=op.f("fk_transfer_dismissals_transaction_id_b_transactions"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_transfer_dismissals_user_id_users")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_transfer_dismissals")),
        sa.UniqueConstraint(
            "user_id",
            "transaction_id_a",
            "transaction_id_b",
            name=op.f("uq_transfer_dismissals_user_id"),
        ),
    )
    op.create_index(
        op.f("ix_transfer_dismissals_user_id"),
        "transfer_dismissals",
        ["user_id"],
        unique=False,
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_transfer_dismissals_user_id"), table_name="transfer_dismissals")
    op.drop_table("transfer_dismissals")
    op.drop_index(op.f("ix_transfers_user_id"), table_name="transfers")
    op.drop_table("transfers")
