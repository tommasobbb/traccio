"""manual accounts: nullable connection_id and identification_hash.

Manual accounts (``docs/decisions/0020-manual-accounts.md``) are accounts the
user creates and maintains by hand — a cash float, an investment pass-through —
with no bank consent behind them. They carry ``connection_id`` and
``identification_hash`` both ``NULL``:

- ``connection_id`` — previously ``NOT NULL`` with a foreign key to
  ``connections``. Now nullable; the foreign key is unchanged (a set value
  still has to name a real connection).
- ``identification_hash`` — previously ``NOT NULL``. Now nullable. It is part
  of the ``(user_id, identification_hash)`` unique constraint, and that is
  deliberately fine: ``NULL != NULL`` in SQL, so any number of manual accounts
  per user coexist, and a sync's ``upsert_account`` (which matches on that
  pair) can never match a manual row.

No data backfill — every existing account is synced and keeps both values.
No new column: whether an account is manual is derived from ``connection_id``
(``domain/accounts.py::account_source``), never stored. The new
``AccountKind.CASH`` and ``KeyStrategy.MANUAL`` members need no migration —
enum columns are constraint-free ``VARCHAR`` (``traccio.db.models``) and
``cash``/``manual`` fit the existing widths.

Both ``ALTER COLUMN`` changes go through ``batch_alter_table`` so they are
valid on SQLite, which cannot alter a column's nullability without a table
rebuild — same pattern as ``d1f4b6a29c73_widen_transaction_status.py`` and
``b2c3d4e5f6a7_category_hierarchy_and_appearance.py``.

Revision ID: d4e5f6a7b8c9
Revises: b2c3d4e5f6a7
Create Date: 2026-08-27 18:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "d4e5f6a7b8c9"
down_revision: str | Sequence[str] | None = "b2c3d4e5f6a7"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema: drop the two NOT NULLs on ``accounts``."""
    with op.batch_alter_table("accounts") as batch_op:
        batch_op.alter_column(
            "connection_id",
            existing_type=sa.Uuid(),
            nullable=True,
        )
        batch_op.alter_column(
            "identification_hash",
            existing_type=sa.Text(),
            nullable=True,
        )


def downgrade() -> None:
    """Downgrade schema.

    Restoring the ``NOT NULL``s would fail on any database that already holds a
    manual account (both columns ``NULL`` by design). A downgrade past this
    revision therefore requires deleting manual accounts first; the migration
    does not do that silently.
    """
    with op.batch_alter_table("accounts") as batch_op:
        batch_op.alter_column(
            "identification_hash",
            existing_type=sa.Text(),
            nullable=False,
        )
        batch_op.alter_column(
            "connection_id",
            existing_type=sa.Uuid(),
            nullable=False,
        )
