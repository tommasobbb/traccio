"""Repositories: the only place SQL queries are written.

Every function is scoped by ``user_id`` — there is no path that returns rows
across users (see ``docs/architecture.md``). Rows are translated to domain
objects on the way out via :mod:`traccio.db.mappers`, so callers above ``db/``
never see ORM types.
"""

from datetime import datetime
from uuid import UUID

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from traccio.db.mappers import (
    account_to_row,
    connection_to_row,
    row_to_account,
    row_to_connection,
    row_to_transaction,
    transaction_to_row,
)
from traccio.db.models import AccountRow, ConnectionRow, TransactionRow
from traccio.domain.enums import ConnectionStatus, TransactionStatus
from traccio.domain.models import Account, Connection, Transaction


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


def upsert_account(session: Session, *, account: Account) -> Account:
    """Insert an account or update it in place if already known.

    Idempotent on ``(user_id, identification_hash)``: an account re-exposed
    through a new consent updates the existing row (its ``connection_id``,
    ``kind``, ``currency``, ``name``) rather than duplicating, keeping the
    original ``id`` and ``created_at`` stable so downstream references survive a
    re-sync (see ``docs/architecture.md``). Scoped by ``user_id``. Uses a
    read-then-write pattern (no dialect-specific upsert) so it behaves the same
    on SQLite and PostgreSQL. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    account : Account
        The domain account to persist. Its ``user_id`` scopes the match.

    Returns
    -------
    Account
        The persisted account: the newly inserted one, or the existing one with
        its mutable fields refreshed (original ``id``/``created_at`` preserved).
    """
    existing = session.scalars(
        select(AccountRow).where(
            AccountRow.user_id == account.user_id,
            AccountRow.identification_hash == account.identification_hash,
        )
    ).one_or_none()
    if existing is None:
        row = account_to_row(account)
        session.add(row)
        return row_to_account(row)

    existing.connection_id = account.connection_id
    existing.kind = account.kind
    existing.currency = account.currency
    existing.name = account.name
    return row_to_account(existing)


def upsert_transaction(session: Session, *, transaction: Transaction) -> Transaction:
    """Insert a transaction or update a still-pending one in place.

    Idempotent on ``(account_id, stable_key)`` — the unique constraint that makes
    a re-sync change nothing (``docs/architecture.md``). Read-then-write (no
    dialect-specific upsert) so it behaves the same on SQLite and PostgreSQL. The
    caller owns the transaction boundary and commits.

    Conflict handling follows the domain's immutability rule
    (``docs/domain.md``):

    - An existing **terminal** row (``booked`` or ``rejected``) is immutable —
      corrections arrive as new transactions — so it is returned untouched.
    - An existing **pending** row is the *same* movement transitioning state (its
      amount/description routinely change on settlement, and it may settle to
      ``booked`` or be ``rejected``), so the bank-sourced fields are refreshed.
      User- and detection-owned fields (``role``, ``display_description``) are
      **never** overwritten by a sync, and the ``id`` is preserved so references
      survive.

    Parameters
    ----------
    session : Session
        Active database session.
    transaction : Transaction
        The normalized domain transaction to persist. Its ``account_id`` and
        ``stable_key`` identify the row.

    Returns
    -------
    Transaction
        The persisted transaction: the newly inserted one, the refreshed pending
        one, or the untouched booked one.
    """
    existing = session.scalars(
        select(TransactionRow).where(
            TransactionRow.account_id == transaction.account_id,
            TransactionRow.stable_key == transaction.stable_key,
        )
    ).one_or_none()
    if existing is None:
        row = transaction_to_row(transaction)
        session.add(row)
        return row_to_transaction(row)

    if existing.status is not TransactionStatus.PENDING:
        # Terminal (booked or rejected): immutable, returned untouched.
        return row_to_transaction(existing)

    existing.amount = transaction.money.amount
    existing.currency = transaction.money.currency
    existing.booked_at = transaction.booked_at
    existing.value_date = transaction.value_date
    existing.description = transaction.description
    existing.status = transaction.status
    existing.entry_reference = transaction.entry_reference
    existing.key_strategy = transaction.key_strategy
    return row_to_transaction(existing)


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


def list_all_transactions(session: Session, user_id: UUID) -> list[Transaction]:
    """Return every one of the user's transactions, most recent first.

    Scoped by ``user_id``. Unlike :func:`list_transactions` this is unpaginated:
    it feeds in-memory detection (e.g. transfer suggestions), which must see the
    whole pool to pair legs, not one page. Ordering matches the paginated reader
    for consistency but detection does not depend on it. A windowed/incremental
    variant is a later optimization, tied to the background sync scheduler.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to return; the query is scoped to it.

    Returns
    -------
    list[Transaction]
        All domain transactions owned by ``user_id`` (empty if none), newest
        first.
    """
    rows = session.scalars(
        select(TransactionRow)
        .where(TransactionRow.user_id == user_id)
        .order_by(
            func.coalesce(TransactionRow.booked_at, TransactionRow.value_date).desc(),
            TransactionRow.id,
        )
    ).all()
    return [row_to_transaction(row) for row in rows]


def list_transactions(
    session: Session,
    user_id: UUID,
    *,
    account_id: UUID | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[Transaction]:
    """Return the user's transactions, most recent first, paginated.

    Scoped by ``user_id``; the optional ``account_id`` narrows to a single
    account but is always combined with ``user_id``, so it can never expose
    another user's rows. Ordering is most-recent-first on
    ``coalesce(booked_at, value_date)`` (a pending row with no ``booked_at``
    falls back to its ``value_date``), tie-broken by ``id`` for a deterministic,
    stable page order without relying on dialect-specific ``NULLS FIRST/LAST``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to return; the query is scoped to it.
    account_id : UUID or None, optional
        When given, restrict to this account (still scoped by ``user_id``).
    limit : int, optional
        Maximum number of rows to return. The caller (``api/``) validates the
        bounds; the default matches one page.
    offset : int, optional
        Number of rows to skip for pagination.

    Returns
    -------
    list[Transaction]
        Domain transactions owned by ``user_id`` (empty if none), newest first.
    """
    query = select(TransactionRow).where(TransactionRow.user_id == user_id)
    if account_id is not None:
        query = query.where(TransactionRow.account_id == account_id)
    query = (
        query.order_by(
            func.coalesce(TransactionRow.booked_at, TransactionRow.value_date).desc(),
            TransactionRow.id,
        )
        .limit(limit)
        .offset(offset)
    )
    rows = session.scalars(query).all()
    return [row_to_transaction(row) for row in rows]
