"""transaction last_synced_at.

Adds ``transactions.last_synced_at``: a sync-process bookkeeping timestamp,
absent from the domain model (like ``event_id``), the caller
(``db/repositories.py::upsert_transaction``) sets on every row a sync observes
— inserted, refreshed while pending, or re-seen unchanged while terminal.

It exists so a still-``pending`` row can be aged off correctly
(``db/repositories.py::prune_stale_pending_transactions``,
``docs/domain.md``: "pending transactions that neither settle nor reappear
within a defined window are dropped"). Neither ``booked_at`` nor
``value_date`` is reliable for this: both are nullable, and
``docs/openbanking.md`` records a real observed case (Revolut) where a
*pending* entry had ``booked_at`` set and ``value_date`` absent.

Nullable, plain column, no FK — same portable ``add_column``/``drop_column``
shape as the ``connections.country`` migration (``b8f3d2e7c1a4``). Existing
rows get ``NULL`` rather than a backfilled guess: there is no reliable "last
synced" instant to backfill from, and a ``NULL`` is treated as "not yet
eligible for pruning" (see the repository function), never as "eligible by
default" — so this migration cannot cause a surprise mass-delete.

Revision ID: c4d9e3f8a6b5
Revises: b8f3d2e7c1a4
Create Date: 2026-08-21 21:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c4d9e3f8a6b5"
down_revision: str | Sequence[str] | None = "b8f3d2e7c1a4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column(
        "transactions", sa.Column("last_synced_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_index(
        op.f("ix_transactions_last_synced_at"), "transactions", ["last_synced_at"], unique=False
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_transactions_last_synced_at"), table_name="transactions")
    op.drop_column("transactions", "last_synced_at")
