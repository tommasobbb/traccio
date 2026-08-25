"""account alias, color, and icon.

Adds three user-owned appearance columns to ``accounts`` (see
``docs/decisions/0017-semantic-appearance-tokens.md``):

- ``alias`` — the user's own display name, distinct from ``name`` (the
  provider's product name, overwritten on every sync). ``Text``, nullable —
  user-typed free text, not a controlled vocabulary, so no fixed VARCHAR width
  is guessed (the same reasoning as ``identification_hash``,
  ``e2c4a8f1b6d3``).
- ``color`` / ``icon`` — appearance tokens (``PaletteColor`` / ``AccountIcon``),
  stored via ``_token_column``'s fixed-width ``VARCHAR(32)`` rather than
  ``_enum_column``'s current-longest-member width, so a future token never
  needs a widening migration like ``d1f4b6a29c73`` or this migration's own
  predecessor had to.

Pure additive columns, all nullable — no backfill needed (an account with no
alias/color/icon set simply falls back to the provider name and a default
appearance, both resolved client-side). No new foreign key, so no SQLite/
PostgreSQL split is needed here.

Revision ID: a1b2c3d4e5f6
Revises: e2c4a8f1b6d3
Create Date: 2026-08-25 18:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a1b2c3d4e5f6"
down_revision: str | Sequence[str] | None = "e2c4a8f1b6d3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("accounts", sa.Column("alias", sa.Text(), nullable=True))
    op.add_column(
        "accounts",
        sa.Column(
            "color",
            sa.Enum(
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
            ),
            nullable=True,
        ),
    )
    op.add_column(
        "accounts",
        sa.Column(
            "icon",
            sa.Enum(
                "bank",
                "card",
                "wallet",
                "savings",
                "cash",
                "phone",
                name="accounticon",
                native_enum=False,
                length=32,
            ),
            nullable=True,
        ),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("accounts", "icon")
    op.drop_column("accounts", "color")
    op.drop_column("accounts", "alias")
