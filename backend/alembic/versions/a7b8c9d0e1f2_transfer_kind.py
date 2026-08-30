"""transfers: add a ``kind`` column (two_sided | funded_payment).

A funded payment (``docs/decisions/0022-funded-payment-pairing.md``) is a card
charge on a real account that tops up a wallet so the wallet can pay a merchant
— e.g. PayPal drawing on a Revolut card. The bank never reports the top-up as
its own credit, so both legs are outflows and the classic opposite-sign
``Transfer`` cannot represent the pair. ``kind`` distinguishes the two:

- ``two_sided`` — the pre-existing behaviour: an opposite-sign pair, both legs
  set to ``role=transfer``.
- ``funded_payment`` — two outflows; only the funding leg
  (``outgoing_transaction_id``) is set to ``role=funding``, the funded leg
  (``incoming_transaction_id``) stays ``personal`` and is the real expense.

Every existing ``transfers`` row predates the concept and is a two-sided
transfer, so the column is added nullable, backfilled to ``two_sided``, then
made ``NOT NULL`` — the same add/backfill/alter shape as
``b2c3d4e5f6a7_category_hierarchy_and_appearance.py``. The ``batch_alter_table``
wrapper keeps the ``NOT NULL`` change valid on SQLite.

The new ``TransactionRole.FUNDING`` member needs no migration: role is a
constraint-free ``VARCHAR`` (``traccio.db.models``) and ``funding`` (7 chars)
fits the existing width comfortably.

Revision ID: a7b8c9d0e1f2
Revises: f6a7b8c9d0e1
Create Date: 2026-08-30 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a7b8c9d0e1f2"
down_revision: str | Sequence[str] | None = "f6a7b8c9d0e1"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Frozen-in-time: the TransferKind members as of this migration. A literal, not
# an import from domain/enums.py — a migration must not change behaviour if that
# module is edited later.
_TRANSFER_KIND = sa.Enum(
    "two_sided",
    "funded_payment",
    name="transferkind",
    native_enum=False,
)
_DEFAULT_KIND = "two_sided"


def _transfers_table() -> sa.Table:
    """A minimal, ad hoc handle for the backfill UPDATE."""
    metadata = sa.MetaData()
    return sa.Table(
        "transfers",
        metadata,
        sa.Column("kind", sa.String(length=14)),
    )


def upgrade() -> None:
    """Upgrade schema: add ``transfers.kind``, backfill, then require it."""
    op.add_column("transfers", sa.Column("kind", _TRANSFER_KIND, nullable=True))

    transfers = _transfers_table()
    op.execute(transfers.update().where(transfers.c.kind.is_(None)).values(kind=_DEFAULT_KIND))

    with op.batch_alter_table("transfers") as batch_op:
        batch_op.alter_column(
            "kind",
            existing_type=sa.String(length=14),
            nullable=False,
        )


def downgrade() -> None:
    """Downgrade schema: drop ``transfers.kind``.

    A funded-payment transfer left a leg on ``role=funding``; a downgrade past
    this revision does not walk those back (the ``funding`` role value is
    otherwise inert without this feature). Restoring it later is a fresh
    upgrade.
    """
    op.drop_column("transfers", "kind")
