"""categories and transaction category ids.

Adds the ``Category`` foundation (see ``docs/domain.md`` §Category):

- ``categories`` — a user-scoped classification (groceries, transport, rent).
  Unique on ``(user_id, name)``: two users may share a name, one user may not
  have two categories with the same name.
- ``transactions.suggested_category_id`` — written by the categorization
  engine, overwritten freely on every re-run. No engine exists yet (that is a
  later slice); the column exists so this slice's endpoints and tests have
  something to exercise the fallback with.
- ``transactions.confirmed_category_id`` — written only by explicit user
  action, never by any automated process.

Unlike ``events and transaction membership`` (``c3f7a9e1d4b2``), both new
transaction columns **are** mirrored on the domain ``Transaction`` model — a
category is an attribute of the movement, not a cross-transaction grouping —
but the same portability split applies to the schema: the columns and their
indexes are added the same way on both dialects, while the foreign-key
**constraints** are added only where ``ALTER TABLE ... ADD CONSTRAINT`` is
supported. SQLite cannot alter constraints in place (batch/copy-move only) and
does not enforce foreign keys in our dev setup anyway; on PostgreSQL, the real
target of ``alembic check``, the constraints are created. The ORM model
declares both FKs regardless, so ``Base.metadata.create_all`` (used by the
tests) builds them inline.

Revision ID: f2a6c9d4b7e1
Revises: d1f4b6a29c73
Create Date: 2026-08-21 16:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "f2a6c9d4b7e1"
down_revision: str | Sequence[str] | None = "d1f4b6a29c73"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "categories",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_categories_user_id_users")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_categories")),
        sa.UniqueConstraint("user_id", "name", name=op.f("uq_categories_user_id")),
    )
    op.create_index(op.f("ix_categories_user_id"), "categories", ["user_id"], unique=False)

    # The columns and their indexes are portable; the FK constraints are added
    # only where ALTER ... ADD CONSTRAINT is supported (not SQLite — see the
    # module docstring).
    op.add_column("transactions", sa.Column("suggested_category_id", sa.Uuid(), nullable=True))
    op.add_column("transactions", sa.Column("confirmed_category_id", sa.Uuid(), nullable=True))
    op.create_index(
        op.f("ix_transactions_suggested_category_id"),
        "transactions",
        ["suggested_category_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_transactions_confirmed_category_id"),
        "transactions",
        ["confirmed_category_id"],
        unique=False,
    )
    if op.get_bind().dialect.name != "sqlite":
        op.create_foreign_key(
            op.f("fk_transactions_suggested_category_id_categories"),
            "transactions",
            "categories",
            ["suggested_category_id"],
            ["id"],
        )
        op.create_foreign_key(
            op.f("fk_transactions_confirmed_category_id_categories"),
            "transactions",
            "categories",
            ["confirmed_category_id"],
            ["id"],
        )


def downgrade() -> None:
    """Downgrade schema."""
    if op.get_bind().dialect.name != "sqlite":
        op.drop_constraint(
            op.f("fk_transactions_confirmed_category_id_categories"),
            "transactions",
            type_="foreignkey",
        )
        op.drop_constraint(
            op.f("fk_transactions_suggested_category_id_categories"),
            "transactions",
            type_="foreignkey",
        )
    op.drop_index(op.f("ix_transactions_confirmed_category_id"), table_name="transactions")
    op.drop_index(op.f("ix_transactions_suggested_category_id"), table_name="transactions")
    op.drop_column("transactions", "confirmed_category_id")
    op.drop_column("transactions", "suggested_category_id")
    op.drop_index(op.f("ix_categories_user_id"), table_name="categories")
    op.drop_table("categories")
