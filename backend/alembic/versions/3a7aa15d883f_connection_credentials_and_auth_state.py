"""connection credentials and auth_state

Adds the two secret/transient columns the Enable Banking consent flow needs on
``connections`` (see ``docs/openbanking.md`` §Consent flow):

- ``encrypted_credentials`` — the provider ``session_id`` encrypted at rest
  (Fernet, ADR 0003); ``NULL`` while pending.
- ``auth_state`` — the anti-CSRF ``state`` matching the SCA callback to a pending
  connection; unique, cleared on activation.

Uses ``batch_alter_table`` so it applies on both SQLite (local checks) and
PostgreSQL.

Revision ID: 3a7aa15d883f
Revises: cc145c9fa364
Create Date: 2026-08-20 18:40:41.549215

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "3a7aa15d883f"
down_revision: str | Sequence[str] | None = "cc145c9fa364"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    with op.batch_alter_table("connections", schema=None) as batch_op:
        batch_op.add_column(sa.Column("encrypted_credentials", sa.Text(), nullable=True))
        batch_op.add_column(sa.Column("auth_state", sa.String(length=128), nullable=True))
        batch_op.create_unique_constraint(op.f("uq_connections_auth_state"), ["auth_state"])


def downgrade() -> None:
    """Downgrade schema."""
    with op.batch_alter_table("connections", schema=None) as batch_op:
        batch_op.drop_constraint(op.f("uq_connections_auth_state"), type_="unique")
        batch_op.drop_column("auth_state")
        batch_op.drop_column("encrypted_credentials")
