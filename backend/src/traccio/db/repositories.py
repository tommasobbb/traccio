"""Repositories: the only place SQL queries are written.

Every function is scoped by ``user_id`` — there is no path that returns rows
across users (see ``docs/architecture.md``). Rows are translated to domain
objects on the way out via :mod:`traccio.db.mappers`, so callers above ``db/``
never see ORM types.
"""

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from traccio.db.mappers import row_to_account
from traccio.db.models import AccountRow
from traccio.domain.models import Account


def list_accounts(session: Session, user_id: UUID) -> list[Account]:
    """Return the user's accounts, oldest first.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose accounts to return; the query is scoped to it.

    Returns
    -------
    list[Account]
        Domain accounts owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(AccountRow).where(AccountRow.user_id == user_id).order_by(AccountRow.created_at)
    ).all()
    return [row_to_account(row) for row in rows]
