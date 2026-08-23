"""connection last_synced_at.

Adds ``connections.last_synced_at``: when a sync last ran against a
connection (``POST /connections/{id}/sync``), stamped by
``db/repositories.py::mark_connection_synced``. It exists so the client's
Conti screen can render "sincronizzato N min fa" per connection —
``docs/design/canvas/Accounts.dc.html`` — without inventing the figure
client-side; the client never derives values the backend owns
(``client/CLAUDE.md``).

Unlike ``transactions.last_synced_at`` (``c4d9e3f8a6b5``), this is a plain
display timestamp with no pruning logic reading it, so no index is needed.
Nullable, plain column, no FK — the same portable ``add_column``/
``drop_column`` shape as ``connections.country`` (``b8f3d2e7c1a4``). Existing
rows get ``NULL``, read by the API as "never synced" (accurate for a
connection whose only syncs predate this column, and safe: nothing treats
``NULL`` as a special case).

Revision ID: e7b2a4c8f915
Revises: c4d9e3f8a6b5
Create Date: 2026-08-23 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e7b2a4c8f915"
down_revision: str | Sequence[str] | None = "c4d9e3f8a6b5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column(
        "connections", sa.Column("last_synced_at", sa.DateTime(timezone=True), nullable=True)
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("connections", "last_synced_at")
