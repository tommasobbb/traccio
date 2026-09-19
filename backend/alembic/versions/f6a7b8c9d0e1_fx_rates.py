"""fx rates cache.

Adds ``fx_rates`` — cached ECB reference rates for the opt-in dashboard
combined total (``docs/decisions/0021-fx-conversion-dashboard.md``). One row
per ``(base, quote, rate_date)``; ``rate`` is an exact decimal string, never a
float or ``Numeric`` (root ``docs/engineering.md``: money is never floating point).

**Not scoped by ``user_id``** — ECB rates are public reference data, identical
for every user, the same category as the seeded ``Category`` templates. This
is the one table with no ``user_id`` column, and the ADR records it as a
deliberate exception.

Plain ``create_table`` with a unique constraint and no foreign keys —
identical portable shape on SQLite and PostgreSQL (same as
``9143acccc245_sync_runs.py``).

Revision ID: f6a7b8c9d0e1
Revises: e5f6a7b8c9d0
Create Date: 2026-08-27 21:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "f6a7b8c9d0e1"
down_revision: str | Sequence[str] | None = "e5f6a7b8c9d0"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "fx_rates",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("base", sa.String(length=3), nullable=False),
        sa.Column("quote", sa.String(length=3), nullable=False),
        sa.Column("rate_date", sa.Date(), nullable=False),
        sa.Column("rate", sa.Text(), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_fx_rates")),
        sa.UniqueConstraint(
            "base", "quote", "rate_date", name=op.f("uq_fx_rates_base_quote_rate_date")
        ),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table("fx_rates")
