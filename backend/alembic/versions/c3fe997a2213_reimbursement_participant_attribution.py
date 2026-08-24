"""reimbursement participant attribution.

Adds ``reimbursements.participant_id`` — an optional, explicit attribution of
one reimbursement to one :class:`~traccio.domain.models.Participant` of the
same advance (ADR 0012, ``docs/domain.md`` §Reimbursement). A reimbursement
attributes to **at most one** participant: a real payment covering two
people's shares is recorded as two separate reimbursements, not modeled as a
join table. Unattributed reimbursements (``participant_id`` NULL, the only
option before this migration) still count toward the advance's own total —
this column adds a display/derivation dimension, it changes no existing
arithmetic.

Same portability pattern as ``transactions.event_id``
(``c3f7a9e1d4b2_events_and_membership.py``): the column and its index are
added identically on SQLite and PostgreSQL, but the foreign-key
**constraint** only where ``ALTER TABLE ... ADD CONSTRAINT`` is supported —
SQLite cannot alter constraints in place and does not enforce foreign keys in
our dev setup anyway. The ORM model declares the FK regardless, so
``Base.metadata.create_all`` (used by the tests) builds it inline.

Autogenerate also re-detected the three pre-existing foreign-key constraints
on ``transactions`` (``confirmed_category_id``/``suggested_category_id``/
``event_id``) as "added" — these are not new, see ``9143acccc245_sync_runs.py``
for why autogenerate always re-proposes them against SQLite. Left out here,
same as every migration since.

Revision ID: c3fe997a2213
Revises: 9143acccc245
Create Date: 2026-08-24 20:11:11.050300

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c3fe997a2213"
down_revision: str | Sequence[str] | None = "9143acccc245"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("reimbursements", sa.Column("participant_id", sa.Uuid(), nullable=True))
    op.create_index(
        op.f("ix_reimbursements_participant_id"), "reimbursements", ["participant_id"], unique=False
    )
    if op.get_bind().dialect.name != "sqlite":
        op.create_foreign_key(
            op.f("fk_reimbursements_participant_id_advance_participants"),
            "reimbursements",
            "advance_participants",
            ["participant_id"],
            ["id"],
        )


def downgrade() -> None:
    """Downgrade schema."""
    if op.get_bind().dialect.name != "sqlite":
        op.drop_constraint(
            op.f("fk_reimbursements_participant_id_advance_participants"),
            "reimbursements",
            type_="foreignkey",
        )
    op.drop_index(op.f("ix_reimbursements_participant_id"), table_name="reimbursements")
    op.drop_column("reimbursements", "participant_id")
