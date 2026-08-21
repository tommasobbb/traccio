"""rules.

Adds the ``Rule`` entity (see ``docs/domain.md`` §Rule): a user-defined mapping
from a transaction pattern to a :class:`~traccio.domain.models.Category`,
applied by the categorization engine
(:mod:`traccio.services.categorization`) to write
``transactions.suggested_category_id`` via ``POST /rules/apply``.

``rules`` is a brand-new table, so — unlike the categories migration
(``f2a6c9d4b7e1``), which had to ``ALTER`` two columns onto the existing
``transactions`` table — its foreign keys to ``users`` and ``categories`` are
declared inline in ``CREATE TABLE``, which SQLite supports natively; no
dialect split is needed here. Unique on ``(user_id, match_kind, pattern)``: the
same predicate and pattern twice has no meaning.

Revision ID: a3c8e1f6d2b4
Revises: f2a6c9d4b7e1
Create Date: 2026-08-21 18:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a3c8e1f6d2b4"
down_revision: str | Sequence[str] | None = "f2a6c9d4b7e1"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "rules",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("category_id", sa.Uuid(), nullable=False),
        sa.Column(
            "match_kind",
            sa.Enum(
                "contains",
                "starts_with",
                "equals",
                name="rulematchkind",
                native_enum=False,
            ),
            nullable=False,
        ),
        sa.Column("pattern", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["category_id"], ["categories.id"], name=op.f("fk_rules_category_id_categories")
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name=op.f("fk_rules_user_id_users")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_rules")),
        sa.UniqueConstraint("user_id", "match_kind", "pattern", name=op.f("uq_rules_user_id")),
    )
    op.create_index(op.f("ix_rules_user_id"), "rules", ["user_id"], unique=False)
    op.create_index(op.f("ix_rules_category_id"), "rules", ["category_id"], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_rules_category_id"), table_name="rules")
    op.drop_index(op.f("ix_rules_user_id"), table_name="rules")
    op.drop_table("rules")
