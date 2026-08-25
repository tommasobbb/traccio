"""category hierarchy, colour, and icon.

Adds three columns to ``categories`` (see
``docs/decisions/0018-two-level-category-hierarchy.md`` and
``docs/decisions/0017-semantic-appearance-tokens.md``):

- ``parent_id`` — a self-referential foreign key, nullable. ``NULL`` means a
  root; a set value names the root it nests under. The **strict two-level**
  rule (a child's own ``parent_id`` is never itself a child) is enforced in
  ``domain/categories.py::validate_parent``, not the schema — a database
  cannot portably express "at most two levels."
- ``color`` — an appearance token (``PaletteColor``, ADR 0017), stored via the
  same fixed-width ``VARCHAR(32)`` ``_token_column`` the account-appearance
  migration (``a1b2c3d4e5f6``) introduced. **Not nullable** once backfilled:
  every category always has a colour. Existing rows get one via a literal,
  frozen-in-time name→colour map for the 13 default categories
  (``domain/categories.py::DEFAULT_CATEGORY_TREE`` at the time this migration
  was written — deliberately **not imported**, so a later edit to that tree
  cannot silently rewrite this migration's backfill); any other existing row
  (a category the user created by hand) gets the neutral ``'slate'`` default.
- ``icon`` — an appearance token (``CategoryIcon``), nullable; not backfilled
  (an icon is a smaller, cosmetic loss to skip on migration than a colour).

Deliberately does **not** create the default tree's new child categories for
existing users — ``POST /categories/defaults`` only ever seeds when a user has
zero categories (``db/repositories.py::seed_default_categories``), and
inserting rows here would be exactly the surprise mutation that endpoint was
designed to avoid. An already-seeded user's children come from the new UI.

Column/index adds are portable; the foreign key constraint is added only
where ``ALTER TABLE ... ADD CONSTRAINT`` is supported (not SQLite — see
``f2a6c9d4b7e1_categories.py`` for the same split). The ``NOT NULL`` on
``color`` is applied via ``batch_alter_table`` (SQLite cannot alter a
column's nullability without a table rebuild — see
``d1f4b6a29c73_widen_transaction_status.py`` for the same pattern).

Revision ID: b2c3d4e5f6a7
Revises: a1b2c3d4e5f6
Create Date: 2026-08-25 19:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b2c3d4e5f6a7"
down_revision: str | Sequence[str] | None = "a1b2c3d4e5f6"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Frozen-in-time: the 13 default root names as of this migration, each with the
# colour/icon DEFAULT_CATEGORY_TREE assigned them. Intentionally a literal
# here, not an import from domain/categories.py — a migration must not change
# behaviour if that module is edited later.
_DEFAULT_APPEARANCE: dict[str, tuple[str, str]] = {
    "Groceries": ("green", "groceries"),
    "Dining out": ("orange", "dining"),
    "Transport": ("blue", "transport"),
    "Housing": ("indigo", "housing"),
    "Utilities": ("amber", "utilities"),
    "Health": ("red", "health"),
    "Shopping": ("pink", "shopping"),
    "Entertainment": ("purple", "entertainment"),
    "Travel": ("teal", "travel"),
    "Subscriptions": ("slate", "subscriptions"),
    "Fees": ("slate", "fees"),
    "Income": ("green", "income"),
    "Other": ("slate", "other"),
}

_NEUTRAL_COLOR = "slate"


def _categories_table() -> sa.Table:
    """A minimal, ad hoc table handle for the backfill UPDATEs.

    Not the ORM ``CategoryRow`` — a migration references only the columns it
    touches, via SQLAlchemy Core, so it keeps working even if the ORM model
    changes shape later.
    """
    metadata = sa.MetaData()
    return sa.Table(
        "categories",
        metadata,
        sa.Column("name", sa.String(length=255)),
        sa.Column("color", sa.String(length=32)),
        sa.Column("icon", sa.String(length=32)),
    )


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("categories", sa.Column("parent_id", sa.Uuid(), nullable=True))
    op.add_column(
        "categories",
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
        "categories",
        sa.Column(
            "icon",
            sa.Enum(
                "groceries",
                "dining",
                "coffee",
                "takeout",
                "transport",
                "fuel",
                "public_transport",
                "housing",
                "rent",
                "maintenance",
                "utilities",
                "health",
                "shopping",
                "clothing",
                "electronics",
                "entertainment",
                "streaming",
                "movies",
                "travel",
                "subscriptions",
                "fees",
                "income",
                "other",
                name="categoryicon",
                native_enum=False,
                length=32,
            ),
            nullable=True,
        ),
    )
    op.create_index(op.f("ix_categories_parent_id"), "categories", ["parent_id"], unique=False)

    categories = _categories_table()
    for name, (color, icon) in _DEFAULT_APPEARANCE.items():
        op.execute(
            categories.update().where(categories.c.name == name).values(color=color, icon=icon)
        )
    # Any other existing row (a category the user created by hand) gets the
    # neutral default rather than being left NULL.
    op.execute(categories.update().where(categories.c.color.is_(None)).values(color=_NEUTRAL_COLOR))

    with op.batch_alter_table("categories") as batch_op:
        batch_op.alter_column(
            "color",
            existing_type=sa.String(length=32),
            nullable=False,
        )

    if op.get_bind().dialect.name != "sqlite":
        op.create_foreign_key(
            op.f("fk_categories_parent_id_categories"),
            "categories",
            "categories",
            ["parent_id"],
            ["id"],
        )


def downgrade() -> None:
    """Downgrade schema."""
    if op.get_bind().dialect.name != "sqlite":
        op.drop_constraint(
            op.f("fk_categories_parent_id_categories"), "categories", type_="foreignkey"
        )
    op.drop_index(op.f("ix_categories_parent_id"), table_name="categories")
    op.drop_column("categories", "icon")
    op.drop_column("categories", "color")
    op.drop_column("categories", "parent_id")
