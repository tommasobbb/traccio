"""connection institution logo.

Adds ``connections.institution_logo`` — the bank's logo URL, captured from the
provider's institution list at connect time (Enable Banking's ASPSP ``logo``
field, populated on every IT ASPSP as of 2026-08-27, see
``docs/openbanking.md`` §"Institution discovery"). Rendered by the client in
Conti and the institution picker, with a lettermark fallback.

``Text``, nullable, plain column — same portable ``add_column``/``drop_column``
shape on SQLite and PostgreSQL, no dialect split (same as
``b8f3d2e7c1a4_connection_country.py``). Existing rows get ``NULL``; a
connection created before this column existed shows the lettermark until its
next full re-consent (``POST /connections``) repopulates it.

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-08-27 20:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e5f6a7b8c9d0"
down_revision: str | Sequence[str] | None = "d4e5f6a7b8c9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("connections", sa.Column("institution_logo", sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("connections", "institution_logo")
