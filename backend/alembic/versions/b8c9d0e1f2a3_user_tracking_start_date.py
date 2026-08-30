"""users: add a nullable ``tracking_start_date``.

The first per-user setting in Traccio (ADR 0024). A month before every
account has data shows only the accounts that connected earliest, so its
totals mislead; ``tracking_start_date`` lets the user start the dashboard and
the Movimenti list from a month every account covers.

The column is nullable with no default: ``NULL`` — the state for every
existing user and the state before this column existed — means "no floor,
show everything". It is a ``DATE`` (a whole-day boundary the user picks as a
month), not a ``DATETIME``. No backfill: a plain ``ADD COLUMN`` is valid on
SQLite as well as PostgreSQL when the new column is nullable.

Revision ID: b8c9d0e1f2a3
Revises: a7b8c9d0e1f2
Create Date: 2026-08-30 14:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b8c9d0e1f2a3"
down_revision: str | Sequence[str] | None = "a7b8c9d0e1f2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema: add ``users.tracking_start_date``."""
    op.add_column("users", sa.Column("tracking_start_date", sa.Date(), nullable=True))


def downgrade() -> None:
    """Downgrade schema: drop ``users.tracking_start_date``.

    The setting is a pure display filter, so dropping it loses only the
    stored preference — no movement data.
    """
    op.drop_column("users", "tracking_start_date")
