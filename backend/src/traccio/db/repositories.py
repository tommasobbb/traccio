"""Repositories: the only place SQL queries are written.

Every function is scoped by ``user_id`` — there is no path that returns rows
across users (see ``docs/architecture.md``). Rows are translated to domain
objects on the way out via :mod:`traccio.db.mappers`, so callers above ``db/``
never see ORM types.
"""

from datetime import datetime
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from traccio.db.mappers import connection_to_row, row_to_account
from traccio.db.models import AccountRow, ConnectionRow
from traccio.domain.enums import ConnectionStatus
from traccio.domain.models import Account, Connection


def create_connection(session: Session, *, connection: Connection, auth_state: str) -> None:
    """Persist a new (typically pending) connection with its anti-CSRF state.

    The ``auth_state`` is a db-only column (absent from the domain model), so it
    is set here on the row rather than in the mapper. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    connection : Connection
        The domain connection to store.
    auth_state : str
        The anti-CSRF ``state`` issued for this authorization, used to match the
        callback back to this row.
    """
    row = connection_to_row(connection)
    row.auth_state = auth_state
    session.add(row)


def find_pending_connection_id(
    session: Session, *, user_id: UUID, auth_state: str
) -> UUID | None:
    """Return the id of the pending connection matching ``auth_state``.

    Scoped by ``user_id``. Returns only the id — no ORM row escapes ``db/``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose connections to search; the query is scoped to it.
    auth_state : str
        The ``state`` returned by the SCA callback.

    Returns
    -------
    UUID or None
        The matching connection's id, or ``None`` if no pending connection has
        this state for this user.
    """
    return session.scalars(
        select(ConnectionRow.id).where(
            ConnectionRow.user_id == user_id,
            ConnectionRow.auth_state == auth_state,
        )
    ).one_or_none()


def activate_connection(
    session: Session,
    *,
    user_id: UUID,
    connection_id: UUID,
    encrypted_credentials: str,
    expires_at: datetime | None,
) -> None:
    """Activate a pending connection with its encrypted credentials.

    Sets the status to ``active``, stores the encrypted consent secret and the
    expiry, and clears ``auth_state`` (the authorization is complete). Scoped by
    ``user_id``. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the connection; the update is scoped to it.
    connection_id : UUID
        The connection to activate.
    encrypted_credentials : str
        The provider consent secret, already encrypted at rest.
    expires_at : datetime or None
        Consent expiry, as reported by the provider.
    """
    session.execute(
        update(ConnectionRow)
        .where(ConnectionRow.id == connection_id, ConnectionRow.user_id == user_id)
        .values(
            status=ConnectionStatus.ACTIVE,
            encrypted_credentials=encrypted_credentials,
            expires_at=expires_at,
            auth_state=None,
        )
    )


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
