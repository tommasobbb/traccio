"""connection country.

Adds ``connections.country`` (ISO 3166-1 alpha-2), needed to call
``start_authorization`` again on re-authorization
(``domain/consent.py``, ``POST /connections/{id}/reauthorize``). ``country``
was accepted on ``POST /connections`` from the start but silently dropped —
only ``institution`` was persisted (as ``institution_name``).

Nullable, plain column, no FK — same portable ``add_column``/``drop_column``
shape on both dialects, no dialect split needed (unlike the categories
migration, ``f2a6c9d4b7e1``, which had FK constraints to add only outside
SQLite). Existing rows get ``NULL``; a connection created before this column
existed cannot be re-authorized in place until its next full re-consent
(``POST /connections``), which populates it.

Revision ID: b8f3d2e7c1a4
Revises: a3c8e1f6d2b4
Create Date: 2026-08-21 20:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b8f3d2e7c1a4"
down_revision: str | Sequence[str] | None = "a3c8e1f6d2b4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("connections", sa.Column("country", sa.String(length=2), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("connections", "country")
