"""users: add a non-nullable ``meal_vouchers_enabled``, default ``false``.

The second per-user setting in Traccio (ADR 0029), alongside
``tracking_start_date`` (ADR 0024). Not every user receives meal vouchers, so
the dashboard's "Buoni pasto" breakout (a voucher-kind account's spending,
broken out of the headline totals) is opt-in per user rather than always on.

Unlike ``tracking_start_date``, this column is ``NOT NULL``: a tri-state
"unset" has no meaning here (there is no third state between on and off), so
``server_default=false`` backfills every existing row to "off" — the same
behaviour as before this column existed, when the feature did not exist at
all. A plain ``ADD COLUMN ... DEFAULT false NOT NULL`` is valid on SQLite as
well as PostgreSQL.

Revision ID: a4b6c8d0e2f4
Revises: 5f407e810deb
Create Date: 2026-09-11 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a4b6c8d0e2f4"
down_revision: str | Sequence[str] | None = "5f407e810deb"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema: add ``users.meal_vouchers_enabled``, defaulted ``false``."""
    op.add_column(
        "users",
        sa.Column(
            "meal_vouchers_enabled",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )


def downgrade() -> None:
    """Downgrade schema: drop ``users.meal_vouchers_enabled``.

    Pure preference, so dropping it loses only the stored toggle — no
    account or transaction data.
    """
    op.drop_column("users", "meal_vouchers_enabled")
