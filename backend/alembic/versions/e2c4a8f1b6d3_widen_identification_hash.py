"""widen accounts.identification_hash to Text.

``accounts.identification_hash`` was created as ``VARCHAR(128)``, sized on a
guess. It is Enable Banking's own opaque per-account identity, not a hash this
codebase generates — its length is provider-controlled and not something we
can bound, the same situation as ``ConnectionRow.encrypted_credentials``,
which already uses ``Text`` rather than a fixed ``VARCHAR``.

Invisible on SQLite, which ignores declared ``VARCHAR`` length entirely — the
first real production sync (Fly.io, 2026-08-25, the first Revolut connection
against real Postgres) failed with "value too long for character varying(128)"
on an account whose identification_hash exceeded 128 characters. Local dev
against SQLite never surfaced this, same root cause class as
``d1f4b6a29c73_widen_transaction_status``.

Widens the column in place; wrapped in ``batch_alter_table`` for the same
SQLite-compatibility reason as that prior migration.

Revision ID: e2c4a8f1b6d3
Revises: c3fe997a2213
Create Date: 2026-08-25 19:45:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e2c4a8f1b6d3"
down_revision: str | Sequence[str] | None = "c3fe997a2213"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_OLD_TYPE = sa.String(length=128)
_NEW_TYPE = sa.Text()


def upgrade() -> None:
    """Upgrade schema."""
    with op.batch_alter_table("accounts") as batch_op:
        batch_op.alter_column(
            "identification_hash",
            existing_type=_OLD_TYPE,
            type_=_NEW_TYPE,
            existing_nullable=False,
        )


def downgrade() -> None:
    """Downgrade schema.

    Narrowing back to ``VARCHAR(128)`` would truncate any stored account
    whose identification_hash exceeds that length, so this is intentionally
    not attempted — same refusal as ``d1f4b6a29c73``'s downgrade.
    """
    with op.batch_alter_table("accounts") as batch_op:
        batch_op.alter_column(
            "identification_hash",
            existing_type=_NEW_TYPE,
            type_=_NEW_TYPE,
            existing_nullable=False,
        )
