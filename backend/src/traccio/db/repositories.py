"""Repositories: the only place SQL queries are written.

Every function is scoped by ``user_id`` — there is no path that returns rows
across users (see ``docs/architecture.md``). Rows are translated to domain
objects on the way out via :mod:`traccio.db.mappers`, so callers above ``db/``
never see ORM types.
"""

from collections.abc import Mapping
from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from traccio.db.mappers import (
    account_to_row,
    advance_to_row,
    category_to_row,
    connection_to_row,
    event_to_row,
    participant_to_row,
    reimbursement_to_row,
    row_to_account,
    row_to_advance,
    row_to_category,
    row_to_connection,
    row_to_event,
    row_to_reimbursement,
    row_to_rule,
    row_to_transaction,
    row_to_transfer,
    rule_to_row,
    transaction_to_row,
    transfer_to_row,
)
from traccio.db.models import (
    AccountRow,
    AdvanceParticipantRow,
    AdvanceRow,
    CategoryRow,
    ConnectionRow,
    EventRow,
    ReimbursementRow,
    RuleRow,
    TransactionRow,
    TransferDismissalRow,
    TransferRow,
)
from traccio.domain.categories import default_categories
from traccio.domain.enums import (
    AdvanceStatus,
    ConnectionStatus,
    EventStatus,
    RuleMatchKind,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.models import (
    Account,
    Advance,
    Category,
    Connection,
    Event,
    Reimbursement,
    Rule,
    Transaction,
    Transfer,
)
from traccio.domain.money import Money


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
      User- and detection-owned fields (``role``, ``display_description``,
      ``event_id``, ``suggested_category_id``, ``confirmed_category_id``) are
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


def get_transaction(session: Session, *, user_id: UUID, transaction_id: UUID) -> Transaction | None:
    """Return a single transaction by id, scoped by ``user_id``.

    Returns ``None`` when no transaction with that id belongs to the user, so a
    request naming another user's (or an unknown) transaction cannot read it.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the query is scoped to it.
    transaction_id : UUID
        The transaction to fetch.

    Returns
    -------
    Transaction or None
        The domain transaction, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(TransactionRow).where(
            TransactionRow.id == transaction_id,
            TransactionRow.user_id == user_id,
        )
    ).one_or_none()
    return None if row is None else row_to_transaction(row)


def set_transaction_role(
    session: Session, *, user_id: UUID, transaction_id: UUID, role: TransactionRole
) -> None:
    """Set a transaction's ``role``, scoped by ``user_id``.

    The explicit-user-action write behind confirming/undoing a transfer: it only
    changes ``role`` (never an amount), letting the pure ``effective_amount``
    derivation follow. Scoped by ``user_id``; a no-op if no row matches. The
    caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the update is scoped to it.
    transaction_id : UUID
        The transaction whose role to set.
    role : TransactionRole
        The new role.
    """
    session.execute(
        update(TransactionRow)
        .where(TransactionRow.id == transaction_id, TransactionRow.user_id == user_id)
        .values(role=role)
    )


def create_transfer(session: Session, *, transfer: Transfer) -> Transfer:
    """Persist a confirmed transfer linking two transactions.

    Writes only the ``transfers`` row; setting the two legs' ``role`` is the
    caller's separate, explicit step (see :func:`set_transaction_role`). The
    caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    transfer : Transfer
        The domain transfer to store.

    Returns
    -------
    Transfer
        The persisted transfer.
    """
    row = transfer_to_row(transfer)
    session.add(row)
    return row_to_transfer(row)


def delete_transfer(session: Session, *, user_id: UUID, transfer_id: UUID) -> Transfer | None:
    """Delete a transfer and return it, scoped by ``user_id``.

    Returns the deleted transfer so the caller can revert both legs' ``role`` to
    ``personal`` (that role write is the caller's separate step). Returns
    ``None`` when no transfer with that id belongs to the user, so a request
    naming another user's (or an unknown) transfer changes nothing. The caller
    owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transfer; the query and delete are scoped to it.
    transfer_id : UUID
        The transfer to delete.

    Returns
    -------
    Transfer or None
        The deleted transfer, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(TransferRow).where(
            TransferRow.id == transfer_id,
            TransferRow.user_id == user_id,
        )
    ).one_or_none()
    if row is None:
        return None
    transfer = row_to_transfer(row)
    session.delete(row)
    return transfer


def list_transfers(session: Session, user_id: UUID) -> list[Transfer]:
    """Return the user's confirmed transfers, oldest first.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transfers to return; the query is scoped to it.

    Returns
    -------
    list[Transfer]
        Domain transfers owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(TransferRow).where(TransferRow.user_id == user_id).order_by(TransferRow.created_at)
    ).all()
    return [row_to_transfer(row) for row in rows]


def transfer_exists_for_transaction(
    session: Session, *, user_id: UUID, transaction_id: UUID
) -> bool:
    """Return whether a transaction is already a leg of some transfer.

    Scoped by ``user_id``. Used to refuse confirming a transfer whose leg is
    already linked, so a transaction never belongs to two transfers.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transfers to search; the query is scoped to it.
    transaction_id : UUID
        The transaction to look for on either leg.

    Returns
    -------
    bool
        ``True`` if the transaction is the outgoing or incoming leg of an
        existing transfer for this user.
    """
    row = session.scalars(
        select(TransferRow.id).where(
            TransferRow.user_id == user_id,
            (TransferRow.outgoing_transaction_id == transaction_id)
            | (TransferRow.incoming_transaction_id == transaction_id),
        )
    ).first()
    return row is not None


def create_transfer_dismissal(
    session: Session, *, user_id: UUID, transaction_id_a: UUID, transaction_id_b: UUID
) -> None:
    """Record that the user rejected a pair as a transfer (idempotent).

    The two ids are stored in canonical sorted order so the pair is
    order-independent, and a repeated rejection of the same pair is a no-op
    (idempotent, matching the unique constraint). The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner recording the dismissal; the row is scoped to it.
    transaction_id_a : UUID
        One leg of the rejected pair.
    transaction_id_b : UUID
        The other leg of the rejected pair.
    """
    low, high = sorted((transaction_id_a, transaction_id_b))
    existing = session.scalars(
        select(TransferDismissalRow.id).where(
            TransferDismissalRow.user_id == user_id,
            TransferDismissalRow.transaction_id_a == low,
            TransferDismissalRow.transaction_id_b == high,
        )
    ).one_or_none()
    if existing is not None:
        return
    session.add(
        TransferDismissalRow(
            id=uuid4(),
            user_id=user_id,
            transaction_id_a=low,
            transaction_id_b=high,
            created_at=datetime.now(UTC),
        )
    )


def list_transfer_dismissals(session: Session, user_id: UUID) -> frozenset[frozenset[UUID]]:
    """Return the user's rejected transfer pairs as unordered id pairs.

    Feeds :func:`traccio.services.transfers.detect_transfers` so a rejected
    suggestion is not proposed again. Each pair is a two-element ``frozenset`` of
    transaction ids; the set is order-independent by construction.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose dismissals to return; the query is scoped to it.

    Returns
    -------
    frozenset[frozenset[UUID]]
        The dismissed pairs (empty if none).
    """
    rows = session.execute(
        select(
            TransferDismissalRow.transaction_id_a,
            TransferDismissalRow.transaction_id_b,
        ).where(TransferDismissalRow.user_id == user_id)
    ).all()
    return frozenset(frozenset((a, b)) for a, b in rows)


def _participant_rows(
    session: Session, *, user_id: UUID, advance_id: UUID
) -> list[AdvanceParticipantRow]:
    """Return the participant rows of one advance, scoped by ``user_id``."""
    return list(
        session.scalars(
            select(AdvanceParticipantRow).where(
                AdvanceParticipantRow.user_id == user_id,
                AdvanceParticipantRow.advance_id == advance_id,
            )
        ).all()
    )


def create_advance(session: Session, *, advance: Advance) -> Advance:
    """Persist a new advance and its participants.

    Writes the ``advances`` row plus one ``advance_participants`` row per
    participant. Setting the transaction's ``role`` to ``advance`` is the caller's
    separate, explicit step (see :func:`set_transaction_role`). The caller owns
    the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    advance : Advance
        The domain advance to store (with its participants).

    Returns
    -------
    Advance
        The persisted advance.
    """
    session.add(advance_to_row(advance))
    for participant in advance.participants:
        session.add(participant_to_row(participant, user_id=advance.user_id, advance_id=advance.id))
    return advance


def get_advance(session: Session, *, user_id: UUID, advance_id: UUID) -> Advance | None:
    """Return a single advance (with participants) by id, scoped by ``user_id``.

    Returns ``None`` when no advance with that id belongs to the user.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advance; the query is scoped to it.
    advance_id : UUID
        The advance to fetch.

    Returns
    -------
    Advance or None
        The domain advance, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(AdvanceRow).where(AdvanceRow.id == advance_id, AdvanceRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    return row_to_advance(row, _participant_rows(session, user_id=user_id, advance_id=row.id))


def list_advances(session: Session, user_id: UUID) -> list[Advance]:
    """Return the user's advances (with participants), oldest first.

    Scoped by ``user_id``. Participants are fetched once and grouped in memory to
    avoid a per-advance query.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose advances to return; the query is scoped to it.

    Returns
    -------
    list[Advance]
        Domain advances owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(AdvanceRow).where(AdvanceRow.user_id == user_id).order_by(AdvanceRow.created_at)
    ).all()
    participants: dict[UUID, list[AdvanceParticipantRow]] = {}
    for participant in session.scalars(
        select(AdvanceParticipantRow).where(AdvanceParticipantRow.user_id == user_id)
    ).all():
        participants.setdefault(participant.advance_id, []).append(participant)
    return [row_to_advance(row, participants.get(row.id, [])) for row in rows]


def delete_advance(session: Session, *, user_id: UUID, advance_id: UUID) -> Advance | None:
    """Delete an advance (and its participants) and return it, scoped by ``user_id``.

    Returns the deleted advance so the caller can revert the transaction's ``role``
    to ``personal`` (that role write is the caller's separate step). Returns
    ``None`` when no advance with that id belongs to the user. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advance; the query and delete are scoped to it.
    advance_id : UUID
        The advance to delete.

    Returns
    -------
    Advance or None
        The deleted advance, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(AdvanceRow).where(AdvanceRow.id == advance_id, AdvanceRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    participant_rows = _participant_rows(session, user_id=user_id, advance_id=row.id)
    advance = row_to_advance(row, participant_rows)
    for participant in participant_rows:
        session.delete(participant)
    session.delete(row)
    return advance


def advance_exists_for_transaction(
    session: Session, *, user_id: UUID, transaction_id: UUID
) -> bool:
    """Return whether a transaction already has an advance.

    Scoped by ``user_id``. Used to refuse creating a second advance on the same
    transaction.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose advances to search; the query is scoped to it.
    transaction_id : UUID
        The transaction to look for.

    Returns
    -------
    bool
        ``True`` if an advance for this user already references the transaction.
    """
    row = session.scalars(
        select(AdvanceRow.id).where(
            AdvanceRow.user_id == user_id,
            AdvanceRow.transaction_id == transaction_id,
        )
    ).first()
    return row is not None


def set_advance_status(
    session: Session, *, user_id: UUID, advance_id: UUID, status: AdvanceStatus
) -> None:
    """Set an advance's stored ``status``, scoped by ``user_id``.

    Only the ``written_off`` transition (and its reversal to ``open``) is stored;
    ``settled`` is derived from reimbursements, never written here (see ADR 0004).
    Scoped by ``user_id``; a no-op if no row matches. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advance; the update is scoped to it.
    advance_id : UUID
        The advance whose status to set.
    status : AdvanceStatus
        The new stored status.
    """
    session.execute(
        update(AdvanceRow)
        .where(AdvanceRow.id == advance_id, AdvanceRow.user_id == user_id)
        .values(status=status)
    )


def create_reimbursement(session: Session, *, reimbursement: Reimbursement) -> Reimbursement:
    """Persist a new reimbursement against an advance.

    Writes only the ``reimbursements`` row; flipping a linked transaction's
    ``role`` to ``reimbursement`` is the caller's separate, explicit step (see
    :func:`set_transaction_role`). The caller owns the transaction boundary and
    commits.

    Parameters
    ----------
    session : Session
        Active database session.
    reimbursement : Reimbursement
        The domain reimbursement to store.

    Returns
    -------
    Reimbursement
        The persisted reimbursement.
    """
    session.add(reimbursement_to_row(reimbursement))
    return reimbursement


def list_reimbursements(
    session: Session, *, user_id: UUID, advance_id: UUID
) -> list[Reimbursement]:
    """Return one advance's reimbursements, oldest first, scoped by ``user_id``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose reimbursements to return; the query is scoped to it.
    advance_id : UUID
        The advance whose reimbursements to list.

    Returns
    -------
    list[Reimbursement]
        The advance's reimbursements, oldest first (empty if none).
    """
    rows = session.scalars(
        select(ReimbursementRow)
        .where(
            ReimbursementRow.user_id == user_id,
            ReimbursementRow.advance_id == advance_id,
        )
        .order_by(ReimbursementRow.created_at)
    ).all()
    return [row_to_reimbursement(row) for row in rows]


def delete_reimbursement(
    session: Session, *, user_id: UUID, advance_id: UUID, reimbursement_id: UUID
) -> Reimbursement | None:
    """Delete a reimbursement and return it, scoped by ``user_id``.

    Returns the deleted reimbursement so the caller can revert a linked
    transaction's ``role`` to ``personal`` (that role write is the caller's
    separate step). Returns ``None`` when no matching reimbursement belongs to the
    user and advance. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the reimbursement; the query and delete are scoped to it.
    advance_id : UUID
        The advance the reimbursement belongs to.
    reimbursement_id : UUID
        The reimbursement to delete.

    Returns
    -------
    Reimbursement or None
        The deleted reimbursement, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(ReimbursementRow).where(
            ReimbursementRow.id == reimbursement_id,
            ReimbursementRow.user_id == user_id,
            ReimbursementRow.advance_id == advance_id,
        )
    ).one_or_none()
    if row is None:
        return None
    reimbursement = row_to_reimbursement(row)
    session.delete(row)
    return reimbursement


def sum_reimbursements_by_advance(session: Session, user_id: UUID) -> dict[UUID, Money]:
    """Return the total reimbursed per advance for a user, as ``Money``.

    Aggregates in SQL (one query, not one per advance) so the advances list and
    the transaction projection can derive ``outstanding``/spending without an
    N+1. All of one advance's reimbursements share its currency (enforced when
    they are created), so grouping by ``(advance_id, currency)`` yields one row
    per advance.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose reimbursements to sum; the query is scoped to it.

    Returns
    -------
    dict[UUID, Money]
        Advance id to the sum reimbursed (positive magnitude). Advances with no
        reimbursement are absent from the map.
    """
    rows = session.execute(
        select(
            ReimbursementRow.advance_id,
            ReimbursementRow.currency,
            func.sum(ReimbursementRow.amount),
        )
        .where(ReimbursementRow.user_id == user_id)
        .group_by(ReimbursementRow.advance_id, ReimbursementRow.currency)
    ).all()
    return {
        advance_id: Money(amount=int(total), currency=currency)
        for advance_id, currency, total in rows
    }


def create_event(session: Session, *, event: Event) -> Event:
    """Persist a new event.

    Writes only the ``events`` row; assigning member transactions is a separate,
    explicit step (see :func:`assign_transaction_to_event`). The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    event : Event
        The domain event to store.

    Returns
    -------
    Event
        The persisted event.
    """
    session.add(event_to_row(event))
    return event


def get_event(session: Session, *, user_id: UUID, event_id: UUID) -> Event | None:
    """Return a single event by id, scoped by ``user_id``.

    Returns ``None`` when no event with that id belongs to the user, so a request
    naming another user's (or an unknown) event cannot read it.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the event; the query is scoped to it.
    event_id : UUID
        The event to fetch.

    Returns
    -------
    Event or None
        The domain event, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(EventRow).where(EventRow.id == event_id, EventRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_event(row)


def list_events(session: Session, user_id: UUID) -> list[Event]:
    """Return the user's events, oldest first.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose events to return; the query is scoped to it.

    Returns
    -------
    list[Event]
        Domain events owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(EventRow).where(EventRow.user_id == user_id).order_by(EventRow.created_at)
    ).all()
    return [row_to_event(row) for row in rows]


def delete_event(session: Session, *, user_id: UUID, event_id: UUID) -> Event | None:
    """Delete an event and return it, clearing its members' ``event_id`` first.

    Deleting an event removes only the grouping — the member transactions survive
    with their ``event_id`` set back to ``None`` (see ``docs/domain.md``). The
    members are cleared explicitly (not via a DB cascade) to stay portable across
    SQLite and PostgreSQL, and so a plain foreign key is not violated when the row
    is dropped. Returns ``None`` when no event with that id belongs to the user.
    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the event; the query and delete are scoped to it.
    event_id : UUID
        The event to delete.

    Returns
    -------
    Event or None
        The deleted event, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(EventRow).where(EventRow.id == event_id, EventRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    event = row_to_event(row)
    session.execute(
        update(TransactionRow)
        .where(TransactionRow.user_id == user_id, TransactionRow.event_id == event_id)
        .values(event_id=None)
    )
    session.delete(row)
    return event


def set_event_status(
    session: Session, *, user_id: UUID, event_id: UUID, status: EventStatus
) -> None:
    """Set an event's ``status``, scoped by ``user_id``.

    The write behind closing or reopening an event; purely organizational, it
    never touches any transaction. Scoped by ``user_id``; a no-op if no row
    matches. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the event; the update is scoped to it.
    event_id : UUID
        The event whose status to set.
    status : EventStatus
        The new status.
    """
    session.execute(
        update(EventRow)
        .where(EventRow.id == event_id, EventRow.user_id == user_id)
        .values(status=status)
    )


def get_transaction_event_id(
    session: Session, *, user_id: UUID, transaction_id: UUID
) -> UUID | None:
    """Return the event a transaction is currently grouped under, or ``None``.

    Scoped by ``user_id``. ``None`` means either the transaction has no event or
    it does not belong to the user; the caller establishes existence separately
    (via :func:`get_transaction`) before interpreting the result.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the query is scoped to it.
    transaction_id : UUID
        The transaction whose membership to read.

    Returns
    -------
    UUID or None
        The current ``event_id`` of the transaction, or ``None``.
    """
    return session.scalars(
        select(TransactionRow.event_id).where(
            TransactionRow.id == transaction_id,
            TransactionRow.user_id == user_id,
        )
    ).one_or_none()


def assign_transaction_to_event(
    session: Session, *, user_id: UUID, event_id: UUID, transaction_id: UUID
) -> None:
    """Group a transaction under an event, scoped by ``user_id``.

    Sets ``transactions.event_id`` — the explicit-user-action write behind adding
    a transaction to an event. Membership is orthogonal to ``role`` and never
    changes ``effective_amount``. The caller checks the event and transaction
    exist and that the transaction is not already in a different event; this only
    performs the write. Scoped by ``user_id``. The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of both the event and the transaction; the update is scoped to it.
    event_id : UUID
        The event to group the transaction under.
    transaction_id : UUID
        The transaction to assign.
    """
    session.execute(
        update(TransactionRow)
        .where(TransactionRow.id == transaction_id, TransactionRow.user_id == user_id)
        .values(event_id=event_id)
    )


def unassign_transaction_from_event(
    session: Session, *, user_id: UUID, event_id: UUID, transaction_id: UUID
) -> None:
    """Remove a transaction from an event, scoped by ``user_id``.

    Clears ``transactions.event_id`` only when the transaction is currently a
    member of *this* event, so unassigning from the wrong event is a no-op. The
    transaction itself is untouched. Scoped by ``user_id``. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the update is scoped to it.
    event_id : UUID
        The event the transaction should currently belong to.
    transaction_id : UUID
        The transaction to unassign.
    """
    session.execute(
        update(TransactionRow)
        .where(
            TransactionRow.id == transaction_id,
            TransactionRow.user_id == user_id,
            TransactionRow.event_id == event_id,
        )
        .values(event_id=None)
    )


def list_event_members(session: Session, *, user_id: UUID, event_id: UUID) -> list[Transaction]:
    """Return the transactions grouped under one event, scoped by ``user_id``.

    Feeds the pure :func:`~traccio.domain.events.event_total` derivation, so the
    order is not significant; it matches the transaction readers
    (most-recent-first) for consistency.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to return; the query is scoped to it.
    event_id : UUID
        The event whose members to list.

    Returns
    -------
    list[Transaction]
        The event's member transactions (empty if none).
    """
    rows = session.scalars(
        select(TransactionRow)
        .where(TransactionRow.user_id == user_id, TransactionRow.event_id == event_id)
        .order_by(
            func.coalesce(TransactionRow.booked_at, TransactionRow.value_date).desc(),
            TransactionRow.id,
        )
    ).all()
    return [row_to_transaction(row) for row in rows]


def create_category(session: Session, *, category: Category) -> Category:
    """Persist a new category.

    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    category : Category
        The domain category to store.

    Returns
    -------
    Category
        The persisted category.
    """
    session.add(category_to_row(category))
    return category


def get_category(session: Session, *, user_id: UUID, category_id: UUID) -> Category | None:
    """Return a single category by id, scoped by ``user_id``.

    Returns ``None`` when no category with that id belongs to the user, so a
    request naming another user's (or an unknown) category cannot read it —
    this is the cross-user gate the category-confirming endpoints rely on.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the query is scoped to it.
    category_id : UUID
        The category to fetch.

    Returns
    -------
    Category or None
        The domain category, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(CategoryRow).where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_category(row)


def list_categories(session: Session, user_id: UUID) -> list[Category]:
    """Return the user's categories, alphabetically by name.

    Alphabetical rather than the ``created_at`` order used elsewhere: this list
    is what a category picker renders, and a picker wants alphabetical, not
    chronological.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose categories to return; the query is scoped to it.

    Returns
    -------
    list[Category]
        Domain categories owned by ``user_id``, ordered by name (empty if
        none).
    """
    rows = session.scalars(
        select(CategoryRow).where(CategoryRow.user_id == user_id).order_by(CategoryRow.name)
    ).all()
    return [row_to_category(row) for row in rows]


def category_name_exists(session: Session, *, user_id: UUID, name: str) -> bool:
    """Return whether the user already has a category with this exact name.

    A read-then-write check (rather than catching the unique constraint's
    ``IntegrityError``) so create and rename behave identically on SQLite and
    PostgreSQL.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    name : str
        The exact name to look for (already normalized by the caller).

    Returns
    -------
    bool
        ``True`` if the user has a category with this name.
    """
    return (
        session.scalars(
            select(CategoryRow.id).where(CategoryRow.user_id == user_id, CategoryRow.name == name)
        ).first()
        is not None
    )


def rename_category(session: Session, *, user_id: UUID, category_id: UUID, name: str) -> None:
    """Rename a category, scoped by ``user_id``.

    A category's only mutable field. Scoped by ``user_id``; a no-op if no row
    matches. The caller checks the new name does not collide with another of the
    user's categories before calling this. The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the update is scoped to it.
    category_id : UUID
        The category to rename.
    name : str
        The new name (already normalized by the caller).
    """
    session.execute(
        update(CategoryRow)
        .where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
        .values(name=name)
    )


def delete_category(session: Session, *, user_id: UUID, category_id: UUID) -> Category | None:
    """Delete a category and return it, clearing its suggestions and rules first.

    Clears ``suggested_category_id`` on every transaction that references this
    category — that layer is "overwritten freely on every re-run"
    (``docs/domain.md`` §Category), so it is disposable and the categorization
    engine will re-fill it later. Also deletes every :class:`Rule` targeting this
    category (see :func:`delete_rules_for_category`): a rule pointing at a
    deleted category is broken, and the automation layer is disposable by the
    same reasoning. Both cleared explicitly (not via a DB cascade) to stay
    portable across SQLite and PostgreSQL, and so the delete does not violate a
    plain foreign key.

    Does **not** touch ``confirmed_category_id`` — the caller (the API layer)
    is expected to have already refused the delete via
    :func:`category_is_confirmed_on_any_transaction` when any transaction has
    this category confirmed; nulling user-confirmed data as a side effect of
    deleting a different entity is exactly the automated write to
    ``confirmed_category_id`` the project rule forbids. Returns ``None`` when no
    category with that id belongs to the user. The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the query and delete are scoped to it.
    category_id : UUID
        The category to delete.

    Returns
    -------
    Category or None
        The deleted category, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(CategoryRow).where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    category = row_to_category(row)
    session.execute(
        update(TransactionRow)
        .where(
            TransactionRow.user_id == user_id,
            TransactionRow.suggested_category_id == category_id,
        )
        .values(suggested_category_id=None)
    )
    delete_rules_for_category(session, user_id=user_id, category_id=category_id)
    session.delete(row)
    return category


def category_is_confirmed_on_any_transaction(
    session: Session, *, user_id: UUID, category_id: UUID
) -> bool:
    """Return whether any of the user's transactions has this category confirmed.

    The guard behind refusing to delete a category still in active use: the API
    layer calls this before :func:`delete_category` and returns ``409`` if it is
    ``True``, since deleting would otherwise require nulling user-confirmed data
    (see :func:`delete_category`).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    category_id : UUID
        The category to check.

    Returns
    -------
    bool
        ``True`` if at least one of the user's transactions has this category as
        its ``confirmed_category_id``.
    """
    return (
        session.scalars(
            select(TransactionRow.id).where(
                TransactionRow.user_id == user_id,
                TransactionRow.confirmed_category_id == category_id,
            )
        ).first()
        is not None
    )


def seed_default_categories(session: Session, *, user_id: UUID) -> list[Category]:
    """Create the shared default categories for a user, once.

    Idempotent by construction: inserts :func:`~traccio.domain.categories.default_categories`
    only when the user currently has zero categories, so a user who deliberately
    deleted all of theirs does not have them silently resurrected on a repeat
    call. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        The user to seed.

    Returns
    -------
    list[Category]
        The categories just created, or an empty list if the user already had
        at least one.
    """
    existing = session.scalars(select(CategoryRow.id).where(CategoryRow.user_id == user_id)).first()
    if existing is not None:
        return []
    created = default_categories(user_id)
    for category in created:
        session.add(category_to_row(category))
    return created


def set_confirmed_category(
    session: Session, *, user_id: UUID, transaction_id: UUID, category_id: UUID | None
) -> None:
    """Set or clear a transaction's ``confirmed_category_id``, scoped by ``user_id``.

    **The only write path to ``confirmed_category_id`` in the codebase.** Called
    only from an explicit user action (confirming or clearing a category on a
    transaction) — never from sync, detection, or the categorization engine (see
    ``docs/domain.md`` §Category: "any code path that writes to
    ``confirmed_category_id`` without direct user action is a bug"). Scoped by
    ``user_id``; a no-op if no row matches. The caller checks the category
    exists and belongs to the user before calling this with a non-``None`` value;
    this only performs the write. The caller owns the transaction boundary and
    commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the update is scoped to it.
    transaction_id : UUID
        The transaction whose confirmed category to set or clear.
    category_id : UUID or None
        The category to confirm, or ``None`` to clear back to the suggestion (if
        any).
    """
    session.execute(
        update(TransactionRow)
        .where(TransactionRow.id == transaction_id, TransactionRow.user_id == user_id)
        .values(confirmed_category_id=category_id)
    )


def create_rule(session: Session, *, rule: Rule) -> Rule:
    """Persist a new rule.

    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    rule : Rule
        The domain rule to store.

    Returns
    -------
    Rule
        The persisted rule.
    """
    session.add(rule_to_row(rule))
    return rule


def get_rule(session: Session, *, user_id: UUID, rule_id: UUID) -> Rule | None:
    """Return a single rule by id, scoped by ``user_id``.

    Returns ``None`` when no rule with that id belongs to the user, so a
    request naming another user's (or an unknown) rule cannot read it.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the rule; the query is scoped to it.
    rule_id : UUID
        The rule to fetch.

    Returns
    -------
    Rule or None
        The domain rule, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(RuleRow).where(RuleRow.id == rule_id, RuleRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_rule(row)


def rule_exists(
    session: Session, *, user_id: UUID, match_kind: RuleMatchKind, pattern: str
) -> bool:
    """Return whether the user already has a rule with this exact predicate.

    A read-then-write check (rather than catching the unique constraint's
    ``IntegrityError``), matching the idiom :func:`category_name_exists` uses.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    match_kind : RuleMatchKind
        The exact predicate to look for.
    pattern : str
        The exact pattern to look for (already normalized by the caller).

    Returns
    -------
    bool
        ``True`` if the user has a rule with this ``(match_kind, pattern)``.
    """
    return (
        session.scalars(
            select(RuleRow.id).where(
                RuleRow.user_id == user_id,
                RuleRow.match_kind == match_kind,
                RuleRow.pattern == pattern,
            )
        ).first()
        is not None
    )


def list_rules(session: Session, user_id: UUID) -> list[Rule]:
    """Return the user's rules, ordered by ``created_at`` then ``id``.

    This is creation order, not evaluation order — a rule's precedence depends
    on its pattern length, which only :func:`traccio.services.categorization.evaluation_order`
    computes. Callers that need the firing order apply it to this result; ``db/``
    may not import ``services/`` (see ``docs/architecture.md``).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose rules to return; the query is scoped to it.

    Returns
    -------
    list[Rule]
        Domain rules owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(RuleRow).where(RuleRow.user_id == user_id).order_by(RuleRow.created_at, RuleRow.id)
    ).all()
    return [row_to_rule(row) for row in rows]


def delete_rule(session: Session, *, user_id: UUID, rule_id: UUID) -> Rule | None:
    """Delete a rule and return it, scoped by ``user_id``.

    Returns ``None`` when no rule with that id belongs to the user. The caller
    owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the rule; the query and delete are scoped to it.
    rule_id : UUID
        The rule to delete.

    Returns
    -------
    Rule or None
        The deleted rule, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(RuleRow).where(RuleRow.id == rule_id, RuleRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    rule = row_to_rule(row)
    session.delete(row)
    return rule


def delete_rules_for_category(session: Session, *, user_id: UUID, category_id: UUID) -> int:
    """Delete every rule targeting ``category_id``, scoped by ``user_id``.

    Called from :func:`delete_category` when its target category is removed — a
    rule pointing at a category that no longer exists is broken, and the
    automation layer is disposable by design (same reasoning already applied to
    ``suggested_category_id`` there). The caller owns the transaction boundary
    and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the rules; the query and delete are scoped to it.
    category_id : UUID
        The category whose rules should be removed.

    Returns
    -------
    int
        The number of rules deleted.
    """
    rows = session.scalars(
        select(RuleRow).where(RuleRow.user_id == user_id, RuleRow.category_id == category_id)
    ).all()
    for row in rows:
        session.delete(row)
    return len(rows)


def set_suggested_categories(
    session: Session, *, user_id: UUID, assignments: Mapping[UUID, UUID | None]
) -> tuple[int, int]:
    """Bulk-write ``suggested_category_id`` for a set of transactions.

    **The writer** ``docs/domain.md`` §Category calls out as missing until the
    categorization engine exists — called only from ``POST /rules/apply``
    (:mod:`traccio.services.categorization`). Never touches
    ``confirmed_category_id``. Grouped into one ``UPDATE`` per distinct target
    category plus one for the clears, rather than one statement per transaction,
    since ``assignments`` is typically the user's entire transaction pool.
    Transaction ids not owned by ``user_id`` are silently unaffected by the
    ``user_id`` scoping on every statement. The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transactions; every update is scoped to it.
    assignments : Mapping[UUID, UUID or None]
        Transaction id -> suggested category id (``None`` clears it).

    Returns
    -------
    tuple[int, int]
        ``(matched, cleared)`` — how many transaction ids were assigned a
        category and how many were cleared, out of ``assignments`` (not how many
        rows actually changed value).
    """
    by_category: dict[UUID | None, list[UUID]] = {}
    for transaction_id, category_id in assignments.items():
        by_category.setdefault(category_id, []).append(transaction_id)

    matched = 0
    cleared = 0
    for category_id, transaction_ids in by_category.items():
        session.execute(
            update(TransactionRow)
            .where(
                TransactionRow.user_id == user_id,
                TransactionRow.id.in_(transaction_ids),
            )
            .values(suggested_category_id=category_id)
        )
        if category_id is None:
            cleared += len(transaction_ids)
        else:
            matched += len(transaction_ids)

    return matched, cleared
