"""Connection queries: create, activate, credentials, listing, logos."""

from datetime import datetime
from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    connection_to_row,
    row_to_connection,
)
from traccio.db.models import (
    ConnectionRow,
)
from traccio.domain.enums import (
    ConnectionStatus,
)
from traccio.domain.models import (
    Connection,
)


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


def find_pending_connection_id(session: Session, *, user_id: UUID, auth_state: str) -> UUID | None:
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


def set_connection_auth_state(
    session: Session, *, user_id: UUID, connection_id: UUID, auth_state: str
) -> None:
    """Re-arm an existing connection with a freshly issued anti-CSRF ``state``.

    Used by re-authorization: unlike :func:`create_connection`, this does not
    create a new row — it lets an already-``active`` (or ``expired``) connection
    go through the SCA handshake again while keeping its id, and therefore its
    accounts and their transaction history, attached.
    :func:`find_pending_connection_id` matches on ``auth_state`` alone, not on
    ``status``, so the callback finds this row regardless of its current status.
    Scoped by ``user_id``. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the connection; the update is scoped to it.
    connection_id : UUID
        The connection to re-arm.
    auth_state : str
        The freshly generated anti-CSRF ``state`` for this authorization
        attempt.
    """
    session.execute(
        update(ConnectionRow)
        .where(ConnectionRow.id == connection_id, ConnectionRow.user_id == user_id)
        .values(auth_state=auth_state)
    )


def get_connection(session: Session, *, user_id: UUID, connection_id: UUID) -> Connection | None:
    """Return a single connection by id, scoped by ``user_id``.

    Returns ``None`` when no connection with that id belongs to the user, so a
    request naming another user's (or an unknown) connection cannot read it.
    Unlike :func:`get_connection_credentials`, this returns the domain object
    (status, ``expires_at``, ``country``) regardless of status, for callers that
    need to reason about a connection that is not currently active (e.g. the
    consent-expiry gate and re-authorization).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the connection; the query is scoped to it.
    connection_id : UUID
        The connection to fetch.

    Returns
    -------
    Connection or None
        The domain connection, or ``None`` if it does not exist or is not the
        caller's.
    """
    row = session.scalars(
        select(ConnectionRow).where(
            ConnectionRow.id == connection_id, ConnectionRow.user_id == user_id
        )
    ).one_or_none()
    return None if row is None else row_to_connection(row)


def mark_connection_synced(
    session: Session, *, user_id: UUID, connection_id: UUID, now: datetime
) -> None:
    """Stamp ``last_synced_at`` on a connection after a sync completes.

    A display-only bookkeeping write: nothing derives from this field, it only
    lets the client render "synced N minutes ago" (``docs/design/canvas/Accounts.dc.html``).
    Scoped by ``user_id``; the caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the connection; the update is scoped to it.
    connection_id : UUID
        The connection that was just synced.
    now : datetime
        The current time, timezone-aware, stamped onto ``last_synced_at``.
    """
    session.execute(
        update(ConnectionRow)
        .where(ConnectionRow.id == connection_id, ConnectionRow.user_id == user_id)
        .values(last_synced_at=now)
    )


def get_connection_credentials(
    session: Session, *, user_id: UUID, connection_id: UUID
) -> str | None:
    """Return the encrypted credentials of an active connection, or ``None``.

    Scoped by ``user_id``. Returns ``None`` when no connection matches, when it
    is not ``active``, or when it carries no stored credentials — the caller
    treats every one of these as "cannot sync". The value is the ciphertext; it
    is decrypted by the caller (``api/``), never here.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the connection; the query is scoped to it.
    connection_id : UUID
        The connection whose credentials to read.

    Returns
    -------
    str or None
        The encrypted consent secret, or ``None`` if unavailable.
    """
    return session.scalars(
        select(ConnectionRow.encrypted_credentials).where(
            ConnectionRow.id == connection_id,
            ConnectionRow.user_id == user_id,
            ConnectionRow.status == ConnectionStatus.ACTIVE,
        )
    ).one_or_none()


def list_connections(session: Session, user_id: UUID) -> list[Connection]:
    """Return the user's connections, oldest first.

    Scoped by ``user_id``. Secret material (``encrypted_credentials``,
    ``auth_state``) stays on the row and never reaches the domain object the
    mapper produces, so callers above ``db/`` cannot leak it.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose connections to return; the query is scoped to it.

    Returns
    -------
    list[Connection]
        Domain connections owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(ConnectionRow)
        .where(ConnectionRow.user_id == user_id)
        .order_by(ConnectionRow.created_at)
    ).all()
    return [row_to_connection(row) for row in rows]


def list_connections_without_logo(session: Session, user_id: UUID) -> list[Connection]:
    """Return the user's connections that carry no ``institution_logo`` yet.

    Scoped by ``user_id``. For the one-time logo backfill: connections created
    before ``institution_logo`` was persisted (migration ``e5f6a7b8c9d0``)
    have ``NULL`` there and fall back to a lettermark in the client. Ordered
    oldest first, matching :func:`list_connections`.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose connections to return; the query is scoped to it.

    Returns
    -------
    list[Connection]
        The connections with no logo (empty if none).
    """
    rows = session.scalars(
        select(ConnectionRow)
        .where(ConnectionRow.user_id == user_id, ConnectionRow.institution_logo.is_(None))
        .order_by(ConnectionRow.created_at)
    ).all()
    return [row_to_connection(row) for row in rows]


def set_connection_logo(
    session: Session,
    *,
    user_id: UUID,
    connection_id: UUID,
    logo: str,
    country: str | None = None,
) -> None:
    """Persist an institution logo URL (and optionally the country) on one connection.

    Scoped by ``user_id`` — the ``WHERE`` combines it with ``connection_id``,
    so another user's row is never touched. A no-op if the id is unknown or
    not the caller's. The caller commits.

    ``country`` is written only when given and non-``None``: the logo backfill
    resolves it as a side effect of the institution lookup for connections that
    predate the ``country`` column (migration ``b8f3d2e7c1a4``), and persisting
    it there also unblocks in-place re-authorization for those rows.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the connection; the update is scoped to it.
    connection_id : UUID
        The connection to update.
    logo : str
        The logo URL to store.
    country : str or None, optional
        ISO 3166-1 alpha-2 country to persist alongside the logo. Ignored when
        ``None`` (the default), so an existing value is never overwritten.
    """
    values: dict[str, str] = {"institution_logo": logo}
    if country is not None:
        values["country"] = country
    session.execute(
        update(ConnectionRow)
        .where(ConnectionRow.id == connection_id, ConnectionRow.user_id == user_id)
        .values(**values)
    )
