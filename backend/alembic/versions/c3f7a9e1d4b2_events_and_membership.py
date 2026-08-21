"""events and transaction membership.

Adds the Event grouping (see ``docs/domain.md`` §Event):

- ``events`` — a user-defined grouping of transactions from one occasion (a
  trip, a renovation). ``name`` plus an optional ``start_date``/``end_date`` and
  a ``status`` (``active``/``closed``). The total is derived from the members'
  ``effective_amount`` (see :func:`traccio.domain.events.event_total`), never
  stored.
- ``transactions.event_id`` — a nullable foreign key to ``events``. A
  transaction belongs to at most one event; membership is orthogonal to ``role``
  (an event is a reporting lens, not a role). Deleting an event clears its
  members' ``event_id`` first (in the repository), so the foreign key is never
  violated by the delete.

The ``events`` table carries ``user_id`` (every query is scoped by it). Portable
across SQLite (local checks) and PostgreSQL: the ``event_id`` column and its
index are added the same way on both, but the foreign-key **constraint** is
added only where ``ALTER TABLE ... ADD CONSTRAINT`` is supported — SQLite cannot
alter constraints in place (batch/copy-move only), and it does not enforce
foreign keys in our dev setup anyway. On PostgreSQL, the real target of
``alembic check``, the constraint is created. The ORM model declares the FK
regardless, so ``Base.metadata.create_all`` (used by the tests) builds it inline.

Revision ID: c3f7a9e1d4b2
Revises: b5e1f0a2c9d7
Create Date: 2026-08-21 14:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c3f7a9e1d4b2"
down_revision: str | Sequence[str] | None = "b5e1f0a2c9d7"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("start_date", sa.Date(), nullable=True),
        sa.Column("end_date", sa.Date(), nullable=True),
        sa.Column(
            "status",
            sa.Enum("active", "closed", name="eventstatus", native_enum=False),
            nullable=False,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name=op.f("fk_events_user_id_users")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_events")),
    )
    op.create_index(op.f("ix_events_user_id"), "events", ["user_id"], unique=False)

    # The column and its index are portable; the FK constraint is added only where
    # ALTER ... ADD CONSTRAINT is supported (not SQLite — see the module docstring).
    op.add_column("transactions", sa.Column("event_id", sa.Uuid(), nullable=True))
    op.create_index(op.f("ix_transactions_event_id"), "transactions", ["event_id"], unique=False)
    if op.get_bind().dialect.name != "sqlite":
        op.create_foreign_key(
            op.f("fk_transactions_event_id_events"),
            "transactions",
            "events",
            ["event_id"],
            ["id"],
        )


def downgrade() -> None:
    """Downgrade schema."""
    if op.get_bind().dialect.name != "sqlite":
        op.drop_constraint(
            op.f("fk_transactions_event_id_events"), "transactions", type_="foreignkey"
        )
    op.drop_index(op.f("ix_transactions_event_id"), table_name="transactions")
    op.drop_column("transactions", "event_id")
    op.drop_index(op.f("ix_events_user_id"), table_name="events")
    op.drop_table("events")
