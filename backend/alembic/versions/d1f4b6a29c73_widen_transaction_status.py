"""widen transaction status.

``transactions.status`` was created in ``cc145c9fa364`` as ``VARCHAR(7)``, sized
for the two members that existed then (``pending``, ``booked``). ``TransactionStatus``
has since gained ``rejected`` (8 characters, first seen on the PayPal wallet — see
``docs/openbanking.md``), which does not fit. ``_enum_column`` never adds a check
constraint (see ``traccio.db.models``), so nothing enforced the old set of values;
the only real constraint was the column width, and it now truncates or rejects an
insert of a ``rejected`` row on a database that actually enforces ``VARCHAR``
length.

Invisible on SQLite, which ignores declared ``VARCHAR`` length entirely — this is
why the live PayPal sync (M1, 2026-08-20) stored ``rejected`` rows without
complaint there. On PostgreSQL, the real target of ``alembic check``, the insert
fails with "value too long for character varying(7)".

``accounts.kind`` needs no equivalent fix: its widest member remains ``savings``
(7 characters) even after ``wallet`` (6) was added, so the original ``VARCHAR(7)``
already fits.

Widens the column in place; wrapped in ``batch_alter_table`` because SQLite
cannot alter a column's type without a table rebuild (harmless here since SQLite
does not enforce the length either way, but the batch form is what makes the
migration valid to run locally at all).

Revision ID: d1f4b6a29c73
Revises: c3f7a9e1d4b2
Create Date: 2026-08-21 15:30:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "d1f4b6a29c73"
down_revision: str | Sequence[str] | None = "c3f7a9e1d4b2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_OLD_TYPE = sa.String(length=7)
_NEW_TYPE = sa.String(length=8)


def upgrade() -> None:
    """Upgrade schema."""
    with op.batch_alter_table("transactions") as batch_op:
        batch_op.alter_column(
            "status",
            existing_type=_OLD_TYPE,
            type_=_NEW_TYPE,
            existing_nullable=False,
        )


def downgrade() -> None:
    """Downgrade schema.

    Narrowing back to ``VARCHAR(7)`` would truncate any stored ``rejected`` row,
    so this is intentionally not attempted — a downgrade past this revision on a
    database holding such rows is a data-loss operation the migration refuses to
    perform silently. Revert manually if that column width is ever needed again.
    """
    with op.batch_alter_table("transactions") as batch_op:
        batch_op.alter_column(
            "status",
            existing_type=_NEW_TYPE,
            type_=_NEW_TYPE,
            existing_nullable=False,
        )
