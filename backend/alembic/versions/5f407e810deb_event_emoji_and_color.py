"""events: add a nullable ``emoji`` and ``color``.

Visual identity for an event (ADR 0027): a free-text single ``emoji`` and a
``color`` token from the shared :class:`~traccio.domain.enums.PaletteColor`
vocabulary (ADR 0017). Both nullable with no default — ``NULL`` is the state
for every existing event and the "not chosen yet" state — so this is a plain
``ADD COLUMN`` valid on SQLite and PostgreSQL alike, no backfill.

``emoji`` is ``VARCHAR(16)``: wide enough for a joined emoji sequence, never a
caption (the API edge validates it is a single emoji). ``color`` reuses the
project's ``_token_column`` — a fixed ``VARCHAR(32)`` so a new palette member
never needs a widening migration.

Revision ID: 5f407e810deb
Revises: b8c9d0e1f2a3
Create Date: 2026-09-09 15:37:56.743616

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "5f407e810deb"
down_revision: str | Sequence[str] | None = "b8c9d0e1f2a3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_PALETTE_COLOR = sa.Enum(
    "blue",
    "indigo",
    "purple",
    "pink",
    "red",
    "orange",
    "amber",
    "green",
    "teal",
    "slate",
    name="palettecolor",
    native_enum=False,
    length=32,
)


def upgrade() -> None:
    """Upgrade schema: add ``events.emoji`` and ``events.color``."""
    op.add_column("events", sa.Column("emoji", sa.String(length=16), nullable=True))
    op.add_column("events", sa.Column("color", _PALETTE_COLOR, nullable=True))


def downgrade() -> None:
    """Downgrade schema: drop ``events.color`` and ``events.emoji``.

    Both are pure presentation, so dropping them loses only the chosen tile
    look — no event or transaction data.
    """
    op.drop_column("events", "color")
    op.drop_column("events", "emoji")
