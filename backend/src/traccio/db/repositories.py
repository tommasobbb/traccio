"""Repositories: the only place SQL queries are written.

Every function is scoped by ``user_id`` — there is no path that returns rows
across users (see ``docs/architecture.md``). Rows are translated to domain
objects on the way out via :mod:`traccio.db.mappers`, so callers above ``db/``
never see ORM types.
"""

from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime
from decimal import Decimal
from typing import TYPE_CHECKING, Any, cast
from uuid import UUID, uuid4

from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    from sqlalchemy import ColumnElement, CursorResult

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
    row_to_sync_run,
    row_to_transaction,
    row_to_transfer,
    rule_to_row,
    sync_run_to_row,
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
    FxRateRow,
    ReimbursementRow,
    RuleRow,
    SyncRunRow,
    TransactionRow,
    TransferDismissalRow,
    TransferRow,
)
from traccio.domain.categories import default_categories
from traccio.domain.enums import (
    AccountIcon,
    AdvanceStatus,
    CategoryIcon,
    ConnectionStatus,
    EventStatus,
    KeyStrategy,
    PaletteColor,
    RuleMatchKind,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.fx import FxRate
from traccio.domain.models import (
    Account,
    Advance,
    Category,
    Connection,
    Event,
    Reimbursement,
    Rule,
    SyncRun,
    Transaction,
    Transfer,
)
from traccio.domain.money import Money
from traccio.domain.search import escape_like


def _transaction_when() -> "ColumnElement[datetime | None]":
    """The single "when did this happen" expression for a transaction row.

    ``coalesce(booked_at, value_date)`` — a pending row with no ``booked_at``
    falls back to its ``value_date``. Every query that orders or filters
    transactions by date uses this same expression, so a period filter (e.g.
    :func:`list_transactions`'s ``start``/``end``) can never disagree with the
    ordering, or with another query's own period filter, about which date a
    row belongs to.

    Returns
    -------
    ColumnElement[datetime | None]
        A SQL expression usable in ``.where()``/``.order_by()``.
    """
    return func.coalesce(TransactionRow.booked_at, TransactionRow.value_date)


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


def upsert_account(session: Session, *, account: Account) -> Account:
    """Insert an account or update it in place if already known.

    Idempotent on ``(user_id, identification_hash)``: an account re-exposed
    through a new consent updates the existing row (its ``connection_id``,
    ``kind``, ``currency``, ``name``) rather than duplicating, keeping the
    original ``id`` and ``created_at`` stable so downstream references survive a
    re-sync (see ``docs/architecture.md``). Scoped by ``user_id``. Uses a
    read-then-write pattern (no dialect-specific upsert) so it behaves the same
    on SQLite and PostgreSQL. The caller owns the transaction boundary and commits.

    Deliberately does **not** touch ``alias``, ``color``, or ``icon`` on an
    existing row — those are user-owned appearance fields (ADR 0017), and a
    sync overwriting them would silently discard whatever the user chose the
    next time their bank refreshes. This is the load-bearing line of the whole
    account-appearance feature: :func:`set_account_alias` and
    :func:`set_account_appearance` are the *only* writers of those three
    columns.

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
    # existing.alias / .color / .icon: never written here — see the docstring.
    return row_to_account(existing)


def get_account(session: Session, *, user_id: UUID, account_id: UUID) -> Account | None:
    """Return a single account by id, scoped by ``user_id``.

    Returns ``None`` when no account with that id belongs to the user, so a
    request naming another user's (or an unknown) account cannot read or
    mutate it — the same cross-user gate :func:`get_category` provides.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the query is scoped to it.
    account_id : UUID
        The account to fetch.

    Returns
    -------
    Account or None
        The domain account, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(AccountRow).where(AccountRow.id == account_id, AccountRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_account(row)


def set_account_alias(
    session: Session, *, user_id: UUID, account_id: UUID, alias: str | None
) -> None:
    """Set (or, with ``None``, clear) an account's user-chosen alias.

    Scoped by ``user_id``; a no-op if no row matches. The caller normalizes
    ``alias`` (see :func:`~traccio.domain.accounts.normalize_account_alias`)
    before calling this. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the update is scoped to it.
    account_id : UUID
        The account to rename.
    alias : str or None
        The new alias, or ``None`` to clear it and fall back to the provider
        name.
    """
    session.execute(
        update(AccountRow)
        .where(AccountRow.id == account_id, AccountRow.user_id == user_id)
        .values(alias=alias)
    )


def set_account_appearance(
    session: Session,
    *,
    user_id: UUID,
    account_id: UUID,
    color: PaletteColor | None,
    icon: AccountIcon | None,
) -> None:
    """Set an account's colour and icon tokens (a full replace, not a merge).

    Scoped by ``user_id``; a no-op if no row matches. Both tokens are set
    together — the request schema makes both mandatory-but-nullable, so there
    is no "leave the other one alone" case to support. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the update is scoped to it.
    account_id : UUID
        The account to restyle.
    color : PaletteColor or None
        The new colour token, or ``None`` to clear it.
    icon : AccountIcon or None
        The new icon token, or ``None`` to clear it.
    """
    session.execute(
        update(AccountRow)
        .where(AccountRow.id == account_id, AccountRow.user_id == user_id)
        .values(color=color, icon=icon)
    )


def upsert_transaction(session: Session, *, transaction: Transaction, now: datetime) -> Transaction:
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

    Every path — insert, pending refresh, or terminal row re-seen unchanged —
    stamps ``last_synced_at = now``: it means "a sync last observed this row,"
    not "this row's content last changed." A still-``pending`` row that keeps
    getting stamped never goes stale;
    :func:`prune_stale_pending_transactions` is what ages one off once syncs
    stop reporting it.

    Parameters
    ----------
    session : Session
        Active database session.
    transaction : Transaction
        The normalized domain transaction to persist. Its ``account_id`` and
        ``stable_key`` identify the row.
    now : datetime
        The current time, timezone-aware, stamped onto ``last_synced_at``.
        Passed in (the caller's sync already reads the clock once for its
        ``since`` window) rather than read internally, so this stays testable
        with no clock.

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
        row.last_synced_at = now
        session.add(row)
        return row_to_transaction(row)

    if existing.status is not TransactionStatus.PENDING:
        # Terminal (booked or rejected): content immutable, but a sync did
        # observe it again.
        existing.last_synced_at = now
        return row_to_transaction(existing)

    existing.amount = transaction.money.amount
    existing.currency = transaction.money.currency
    existing.booked_at = transaction.booked_at
    existing.value_date = transaction.value_date
    existing.description = transaction.description
    existing.status = transaction.status
    existing.entry_reference = transaction.entry_reference
    existing.key_strategy = transaction.key_strategy
    existing.last_synced_at = now
    return row_to_transaction(existing)


def prune_stale_pending_transactions(session: Session, *, user_id: UUID, cutoff: datetime) -> int:
    """Delete abandoned pending transactions, per ``docs/domain.md``.

    "Pending transactions that neither settle nor reappear within a defined
    window are dropped, not kept as ghosts." A row qualifies only if **all**
    of the following hold, scoped by ``user_id``:

    - ``status == pending`` — a terminal row is never touched.
    - ``last_synced_at`` is set and older than ``cutoff`` — a row with no
      recorded ``last_synced_at`` (it predates the column) is treated as *not
      yet eligible*, never as eligible by default; it becomes prunable once a
      sync stamps it, or is simply left alone forever, no worse than today's
      baseline of never pruning anything.
    - ``role == personal`` — a transfer, advance, or reimbursement leg is
      never still ``personal`` (``validate_advance``/``validate_reimbursement``/
      ``validate_transfer_pair`` all require it), so this one check rules out
      all three without joining their tables.
    - ``event_id IS NULL`` — membership is orthogonal to ``role``
      (``docs/domain.md``), so it needs its own check.
    - ``confirmed_category_id IS NULL`` — a user confirmation, unlike a
      ``suggested_category_id``, is not safe to lose silently.

    This is a hard ``DELETE``, matching the domain rule's "dropped, not kept
    as ghosts" — there is no soft-delete/tombstone concept in this schema.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to prune; the query is scoped to it.
    cutoff : datetime
        Rows with ``last_synced_at`` strictly before this instant are
        eligible. Passed in (the caller computes it from
        ``Settings.pending_transaction_ttl_days``) rather than read
        internally, so this stays testable with no clock.

    Returns
    -------
    int
        How many rows were deleted.
    """
    # Session.execute() is typed to return the generic Result[Any]; a Core
    # DELETE always actually returns a CursorResult, which is what carries
    # rowcount. Cast at this one edge, per .claude/rules/python.md.
    result = cast(
        "CursorResult[Any]",
        session.execute(
            delete(TransactionRow).where(
                TransactionRow.user_id == user_id,
                TransactionRow.status == TransactionStatus.PENDING,
                TransactionRow.last_synced_at.is_not(None),
                TransactionRow.last_synced_at < cutoff,
                TransactionRow.role == TransactionRole.PERSONAL,
                TransactionRow.event_id.is_(None),
                TransactionRow.confirmed_category_id.is_(None),
            )
        ),
    )
    return result.rowcount


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


def create_manual_account(session: Session, *, account: Account) -> Account:
    """Insert a manual account (ADR 0020) — a plain insert, never an upsert.

    Unlike :func:`upsert_account`, there is nothing to match on: a manual
    account has ``connection_id`` and ``identification_hash`` both ``None``, so
    every call creates a new row. The ``Account`` model validator has already
    guaranteed the account is manual-shaped. Scoped by ``account.user_id``; the
    caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    account : Account
        The manual account to persist.

    Returns
    -------
    Account
        The newly inserted account.
    """
    row = account_to_row(account)
    session.add(row)
    return row_to_account(row)


def account_has_transactions(session: Session, *, user_id: UUID, account_id: UUID) -> bool:
    """Return whether any transaction belongs to ``account_id``.

    Scoped by ``user_id``. Used to refuse deleting a manual account that still
    holds movements (``409 account_not_empty``), the same "refuse rather than
    cascade-delete financial data" stance as ``409 category_in_use``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the query is scoped to it.
    account_id : UUID
        The account to check.

    Returns
    -------
    bool
        ``True`` if at least one transaction references the account.
    """
    row = session.scalars(
        select(TransactionRow.id).where(
            TransactionRow.user_id == user_id,
            TransactionRow.account_id == account_id,
        )
    ).first()
    return row is not None


def delete_manual_account(session: Session, *, user_id: UUID, account_id: UUID) -> None:
    """Delete an account row, scoped by ``user_id``.

    A no-op if no row matches. The caller has already verified the account is
    manual and empty (see :func:`account_has_transactions`); this function only
    issues the ``DELETE``. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the delete is scoped to it.
    account_id : UUID
        The account to delete.
    """
    session.execute(
        delete(AccountRow).where(AccountRow.id == account_id, AccountRow.user_id == user_id)
    )


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
        .order_by(_transaction_when().desc(), TransactionRow.id)
    ).all()
    return [row_to_transaction(row) for row in rows]


def list_transactions(
    session: Session,
    user_id: UUID,
    *,
    account_id: UUID | None = None,
    event_id: UUID | None = None,
    category_ids: Sequence[UUID] | None = None,
    uncategorized: bool = False,
    q: str | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[Transaction]:
    """Return the user's transactions, most recent first, paginated.

    Scoped by ``user_id``; every optional filter is always combined with
    ``user_id``, so none can expose another user's rows. Ordering is
    most-recent-first on ``coalesce(booked_at, value_date)`` (a pending row
    with no ``booked_at`` falls back to its ``value_date``), tie-broken by
    ``id`` for a deterministic, stable page order without relying on
    dialect-specific ``NULLS FIRST/LAST``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to return; the query is scoped to it.
    account_id : UUID or None, optional
        When given, restrict to this account (still scoped by ``user_id``).
    event_id : UUID or None, optional
        When given, restrict to transactions grouped under this event.
    category_ids : Sequence[UUID] or None, optional
        When given, restrict to transactions whose **effective** category
        (``coalesce(confirmed_category_id, suggested_category_id)``) is one of
        these ids — mirroring the pure
        ``domain/categories.py::effective_category`` in SQL. A plural filter,
        not a single id: filtering by a root category rolls up its children
        too, and the caller (``api/``) is the one that expands a root id into
        that root plus its children before calling this. The caller also
        rejects combining this with ``uncategorized``; this function does not
        re-check that, it just applies both filters if given both.
    uncategorized : bool, optional
        When true, restrict to transactions with no effective category (the
        same ``coalesce`` expression, ``IS NULL``).
    q : str or None, optional
        Free-text search term, already normalized by the caller (see
        :func:`traccio.domain.search.normalize_search_term`). Matches
        case-insensitively against ``description`` **or**
        ``display_description`` — unlike a rule's ``description``-only match
        (ADR 0005), search is a person looking, not an automated write, so it
        may as well search the cleaned-up text too when one exists.
    start : datetime or None, optional
        Inclusive lower bound on ``coalesce(booked_at, value_date)``, the same
        expression :func:`list_transactions_in_period` filters on — a
        chart drill-down and this list must never disagree about which rows a
        period contains.
    end : datetime or None, optional
        Exclusive upper bound on the same expression (half-open ``[start,
        end)``).
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
    if event_id is not None:
        query = query.where(TransactionRow.event_id == event_id)
    effective_category = func.coalesce(
        TransactionRow.confirmed_category_id, TransactionRow.suggested_category_id
    )
    if category_ids is not None:
        query = query.where(effective_category.in_(category_ids))
    if uncategorized:
        query = query.where(effective_category.is_(None))
    if q is not None:
        pattern = f"%{escape_like(q.lower())}%"
        query = query.where(
            func.lower(TransactionRow.description).like(pattern, escape="\\")
            | func.lower(func.coalesce(TransactionRow.display_description, "")).like(
                pattern, escape="\\"
            )
        )
    when = _transaction_when()
    if start is not None:
        query = query.where(when >= start)
    if end is not None:
        query = query.where(when < end)
    query = query.order_by(when.desc(), TransactionRow.id).limit(limit).offset(offset)
    rows = session.scalars(query).all()
    return [row_to_transaction(row) for row in rows]


def list_transactions_in_period(
    session: Session, user_id: UUID, *, start: datetime | None, end: datetime | None
) -> list[Transaction]:
    """Return the user's transactions within a period, for dashboard aggregation.

    Scoped by ``user_id``. The "when" of a transaction, for this purpose, is
    ``coalesce(booked_at, value_date)`` — the same expression already used to
    order :func:`list_transactions` and :func:`list_all_transactions`, so a
    period filter and the read-back ordering never disagree about which date a
    row belongs to. The period is **half-open** ``[start, end)``: ``start`` is
    inclusive, ``end`` is exclusive, so consecutive calendar periods (e.g. one
    month after another) never double-count a row that falls exactly on the
    boundary. Either bound may be ``None`` to leave that side open.

    A row whose ``coalesce(booked_at, value_date)`` is ``NULL`` (both unset) is
    excluded by any bound on that side, but included when the corresponding
    bound is ``None`` — there is no date to compare, so it can only be judged
    "in range" when nothing constrains that range.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to return; the query is scoped to it.
    start : datetime or None
        Inclusive lower bound, or ``None`` for no lower bound.
    end : datetime or None
        Exclusive upper bound, or ``None`` for no upper bound.

    Returns
    -------
    list[Transaction]
        Domain transactions owned by ``user_id`` within the period (empty if
        none), newest first.
    """
    when = _transaction_when()
    query = select(TransactionRow).where(TransactionRow.user_id == user_id)
    if start is not None:
        query = query.where(when >= start)
    if end is not None:
        query = query.where(when < end)
    query = query.order_by(when.desc(), TransactionRow.id)
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


def create_manual_transaction(
    session: Session,
    *,
    transaction: Transaction,
    confirmed_category_id: UUID | None,
) -> Transaction:
    """Insert a user-entered movement on a manual account (ADR 0020).

    A plain insert, never the :func:`upsert_transaction` read-then-write: a
    manual movement's ``stable_key`` is its own id (``KeyStrategy.MANUAL``), so
    it cannot collide, and there is no bank to reconcile against.
    ``last_synced_at`` is deliberately left ``None`` — no sync ever observes
    this row, and :func:`prune_stale_pending_transactions` therefore never ages
    it (it is also always ``booked``, never ``pending``).

    ``confirmed_category_id`` is written here rather than through
    :func:`transaction_to_row` (which never maps a category id) — this is an
    explicit user action at creation time, the same category the dedicated
    ``POST /transactions/{id}/category`` endpoint would set. Scoped by
    ``transaction.user_id``; the caller owns the transaction boundary and
    commits.

    Parameters
    ----------
    session : Session
        Active database session.
    transaction : Transaction
        The domain transaction to persist. The caller has built it with
        ``status=booked``, ``key_strategy=MANUAL``, and
        ``stable_key=str(id)``.
    confirmed_category_id : UUID or None
        An optional category to confirm on the new row, already verified to
        belong to the user.

    Returns
    -------
    Transaction
        The newly inserted transaction.
    """
    row = transaction_to_row(transaction)
    row.confirmed_category_id = confirmed_category_id
    session.add(row)
    return row_to_transaction(row)


def imported_stable_keys(
    session: Session, *, user_id: UUID, account_ids: Sequence[UUID]
) -> set[str]:
    """Return the ``stable_key``s of already-imported rows on ``account_ids``.

    Used by both the import preview (to mark a row ``already_imported``) and
    the commit (to insert only the missing keys), so the two agree. Filtered to
    ``key_strategy == IMPORTED`` — a manual or synced row could never share a
    key with an import (``"{profile}:..."``), but the filter keeps the scan
    small and the intent explicit. Scoped by ``user_id``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the accounts; the query is scoped to it.
    account_ids : Sequence[UUID]
        The target accounts (the primary account, and the voucher account when
        a split profile is used).

    Returns
    -------
    set[str]
        Every ``stable_key`` already present from a prior import.
    """
    if not account_ids:
        return set()
    keys = session.scalars(
        select(TransactionRow.stable_key).where(
            TransactionRow.user_id == user_id,
            TransactionRow.account_id.in_(account_ids),
            TransactionRow.key_strategy == KeyStrategy.IMPORTED,
        )
    ).all()
    return set(keys)


def create_imported_transactions(session: Session, *, transactions: Sequence[Transaction]) -> int:
    """Insert imported movements onto manual accounts (ADR 0023).

    A plain bulk insert, like :func:`create_manual_transaction` and for the
    same reason: each row's ``stable_key`` (``"{profile}:{external_id}"``) is
    unique by construction, so there is nothing to reconcile. The caller has
    already filtered out keys that :func:`imported_stable_keys` reported as
    present, and verified every target account is manual and the user's.
    ``last_synced_at`` stays ``None`` — no sync observes these rows. The caller
    owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    transactions : Sequence[Transaction]
        Domain transactions built with ``status=booked``,
        ``key_strategy=IMPORTED`` and ``stable_key`` set to the movement's
        ``external_key``.

    Returns
    -------
    int
        The number of rows inserted (``len(transactions)``).
    """
    for transaction in transactions:
        session.add(transaction_to_row(transaction))
    return len(transactions)


def update_manual_transaction(
    session: Session,
    *,
    user_id: UUID,
    transaction_id: UUID,
    amount: int,
    currency: str,
    value_date: datetime,
    description: str,
) -> None:
    """Edit the movement fields of a manual transaction, scoped by ``user_id``.

    Touches only the four user-owned movement fields. ``id``/``stable_key``
    never change (so identity is stable across edits), ``status`` stays
    ``booked``, ``role`` and the category ids are left to their own endpoints,
    and ``last_synced_at`` stays ``None``. A no-op if no row matches. The
    caller has already verified the owning account is manual
    (``409 transaction_not_manual`` otherwise); the caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the update is scoped to it.
    transaction_id : UUID
        The transaction to edit.
    amount : int
        New signed amount in minor units.
    currency : str
        New ISO 4217 currency of ``amount``.
    value_date : datetime
        New value date (timezone-aware, UTC).
    description : str
        New description text.
    """
    session.execute(
        update(TransactionRow)
        .where(TransactionRow.id == transaction_id, TransactionRow.user_id == user_id)
        .values(
            amount=amount,
            currency=currency,
            value_date=value_date,
            description=description,
        )
    )


def transaction_is_linked(session: Session, *, user_id: UUID, transaction_id: UUID) -> bool:
    """Return whether a transaction is a leg of a transfer, advance, or reimbursement.

    Scoped by ``user_id``. Used to refuse deleting a manual transaction that
    something else points at (``409 transaction_in_use``) — the same
    refuse-rather-than-cascade stance as ``409 category_in_use`` /
    ``409 account_not_empty``. Checks every foreign key that references
    ``transactions.id``: ``transfers`` (either leg), ``transfer_dismissals``
    (either side of a rejected pair), ``advances``, and ``reimbursements``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose links to search; every query is scoped to it.
    transaction_id : UUID
        The transaction to look for.

    Returns
    -------
    bool
        ``True`` if any of those tables reference the transaction.
    """
    in_transfer = session.scalars(
        select(TransferRow.id).where(
            TransferRow.user_id == user_id,
            (TransferRow.outgoing_transaction_id == transaction_id)
            | (TransferRow.incoming_transaction_id == transaction_id),
        )
    ).first()
    if in_transfer is not None:
        return True
    in_dismissal = session.scalars(
        select(TransferDismissalRow.id).where(
            TransferDismissalRow.user_id == user_id,
            (TransferDismissalRow.transaction_id_a == transaction_id)
            | (TransferDismissalRow.transaction_id_b == transaction_id),
        )
    ).first()
    if in_dismissal is not None:
        return True
    in_advance = session.scalars(
        select(AdvanceRow.id).where(
            AdvanceRow.user_id == user_id,
            AdvanceRow.transaction_id == transaction_id,
        )
    ).first()
    if in_advance is not None:
        return True
    in_reimbursement = session.scalars(
        select(ReimbursementRow.id).where(
            ReimbursementRow.user_id == user_id,
            ReimbursementRow.transaction_id == transaction_id,
        )
    ).first()
    return in_reimbursement is not None


def delete_manual_transaction(session: Session, *, user_id: UUID, transaction_id: UUID) -> None:
    """Delete a transaction row, scoped by ``user_id``.

    A no-op if no row matches. The caller has already verified the row is on a
    manual account and is not linked to a transfer/advance/reimbursement (see
    :func:`transaction_is_linked`); this function only issues the ``DELETE``.
    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transaction; the delete is scoped to it.
    transaction_id : UUID
        The transaction to delete.
    """
    session.execute(
        delete(TransactionRow).where(
            TransactionRow.id == transaction_id, TransactionRow.user_id == user_id
        )
    )


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


def sum_reimbursements_by_participant(session: Session, user_id: UUID) -> dict[UUID, Money]:
    """Return the total reimbursed per participant for a user, as ``Money``.

    The per-participant sibling of :func:`sum_reimbursements_by_advance` (ADR
    0012), same shape and same reason: one aggregate query for a whole page of
    advances, never one per participant. A reimbursement with no
    ``participant_id`` is excluded — it counts toward the advance's own total
    but toward no participant's.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose reimbursements to sum; the query is scoped to it.

    Returns
    -------
    dict[UUID, Money]
        Participant id to the sum reimbursed (positive magnitude).
        Participants with no attributed reimbursement are absent from the map.
    """
    rows = session.execute(
        select(
            ReimbursementRow.participant_id,
            ReimbursementRow.currency,
            func.sum(ReimbursementRow.amount),
        )
        .where(ReimbursementRow.user_id == user_id, ReimbursementRow.participant_id.is_not(None))
        .group_by(ReimbursementRow.participant_id, ReimbursementRow.currency)
    ).all()
    return {
        participant_id: Money(amount=int(total), currency=currency)
        for participant_id, currency, total in rows
        if participant_id is not None
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


def event_ids_for_transactions(
    session: Session, *, user_id: UUID, transaction_ids: Sequence[UUID]
) -> dict[UUID, UUID]:
    """Return the event membership of a batch of transactions, as a map.

    Scoped by ``user_id``. A single query for the whole page of a
    ``GET /transactions`` response, rather than one :func:`get_transaction_event_id`
    call per row — the batched counterpart to that function. Only entries with
    a non-``None`` ``event_id`` are included, so a caller checks membership
    with a plain ``.get(transaction_id)``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transactions; the query is scoped to it.
    transaction_ids : Sequence[UUID]
        The transactions to look up. An empty sequence returns an empty map
        without querying.

    Returns
    -------
    dict[UUID, UUID]
        Transaction id -> event id, for transactions that belong to one.
    """
    if not transaction_ids:
        return {}
    rows = session.execute(
        select(TransactionRow.id, TransactionRow.event_id).where(
            TransactionRow.user_id == user_id,
            TransactionRow.id.in_(transaction_ids),
            TransactionRow.event_id.is_not(None),
        )
    ).all()
    return {row.id: row.event_id for row in rows if row.event_id is not None}


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
        .order_by(_transaction_when().desc(), TransactionRow.id)
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
    """Return the user's categories: each root, alphabetically, immediately
    followed by its own children, also alphabetically.

    A flat list — not nested — because every consumer (a picker, the rules
    editor, the filter chips) wants a flat list to render with indentation, not
    a tree to walk. The interleaving is done here, in Python, rather than with
    a self-join in SQL: a single ``ORDER BY name`` fetch, split into roots and
    a per-parent grouping, and re-merged — simpler to read than the SQL this
    would take, and correct because the two-level depth guarantee
    (:func:`~traccio.domain.categories.validate_parent`) means every child's
    parent is always a root already in this same list.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose categories to return; the query is scoped to it.

    Returns
    -------
    list[Category]
        Domain categories owned by ``user_id``: roots and children
        interleaved as described above (empty if none).
    """
    rows = session.scalars(
        select(CategoryRow).where(CategoryRow.user_id == user_id).order_by(CategoryRow.name)
    ).all()
    categories = [row_to_category(row) for row in rows]

    children_by_parent: dict[UUID, list[Category]] = {}
    for category in categories:
        if category.parent_id is not None:
            children_by_parent.setdefault(category.parent_id, []).append(category)

    ordered: list[Category] = []
    for category in categories:
        if category.parent_id is None:
            ordered.append(category)
            ordered.extend(children_by_parent.get(category.id, []))
    return ordered


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


def list_child_category_ids(session: Session, *, user_id: UUID, category_id: UUID) -> list[UUID]:
    """Return the ids of a category's direct children, scoped by ``user_id``.

    Always empty for a category that is itself a child — the two-level
    hierarchy means a child never has children of its own
    (:func:`~traccio.domain.categories.validate_parent`).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    category_id : UUID
        The (presumed root) category to find children of.

    Returns
    -------
    list[UUID]
        The ids of every category whose ``parent_id`` is ``category_id``
        (empty if none, including when ``category_id`` does not exist).
    """
    return list(
        session.scalars(
            select(CategoryRow.id).where(
                CategoryRow.user_id == user_id, CategoryRow.parent_id == category_id
            )
        ).all()
    )


def category_has_children(session: Session, *, user_id: UUID, category_id: UUID) -> bool:
    """Return whether a category has at least one direct child.

    The guard behind refusing to delete a parent, and behind refusing to move
    a category-with-children under another root (both would otherwise
    silently orphan or re-parent rows the user organized deliberately).

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
        ``True`` if at least one of the user's categories has this one as its
        ``parent_id``.
    """
    return (
        session.scalars(
            select(CategoryRow.id).where(
                CategoryRow.user_id == user_id, CategoryRow.parent_id == category_id
            )
        ).first()
        is not None
    )


def set_category_appearance(
    session: Session,
    *,
    user_id: UUID,
    category_id: UUID,
    color: PaletteColor,
    icon: CategoryIcon | None,
) -> None:
    """Set a category's colour and icon, scoped by ``user_id``.

    A full replace: both fields are applied together, mirroring
    :func:`set_account_appearance`. Unlike an account's colour, a category's
    ``color`` is never ``None`` — every creation path already resolved one.
    Scoped by ``user_id``; a no-op if no row matches. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the update is scoped to it.
    category_id : UUID
        The category to restyle.
    color : PaletteColor
        The new colour.
    icon : CategoryIcon or None
        The new icon, or ``None`` to clear it.
    """
    session.execute(
        update(CategoryRow)
        .where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
        .values(color=color, icon=icon)
    )


def move_category(
    session: Session, *, user_id: UUID, category_id: UUID, parent_id: UUID | None
) -> None:
    """Set a category's parent, scoped by ``user_id``.

    The caller validates the move first
    (:func:`~traccio.domain.categories.validate_parent` for depth/self-parent,
    :func:`category_has_children` for "moving a category-with-children under
    another root would silently strand its own children two levels deep") —
    this function performs the write unconditionally. A no-op if no row
    matches. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the update is scoped to it.
    category_id : UUID
        The category to move.
    parent_id : UUID or None
        The new parent, or ``None`` to make this category a root.
    """
    session.execute(
        update(CategoryRow)
        .where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
        .values(parent_id=parent_id)
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


def record_sync_run(session: Session, *, sync_run: SyncRun) -> SyncRun:
    """Insert one sync run record.

    Plain insert, never an upsert — every attempt (including a skip) is its
    own immutable row (see the domain docstring). The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    sync_run : SyncRun
        The run to persist.

    Returns
    -------
    SyncRun
        The persisted run, unchanged.
    """
    row = sync_run_to_row(sync_run)
    session.add(row)
    return row_to_sync_run(row)


def count_recent_sync_runs(session: Session, *, connection_id: UUID, since: datetime) -> int:
    """Count sync runs for one connection since ``since``, any outcome.

    The read side of the background fetch budget
    (:func:`~traccio.domain.sync_schedule.sync_decision`): the budget is
    counted in *runs*, not provider HTTP calls (docs/openbanking.md's "~4
    background fetches per day" is read as "~4 sync attempts," since one run
    already makes several provider calls internally). Every outcome counts,
    including a skip, since a skip already means a decision was evaluated for
    this connection in the window — only the interval check below reads
    ``started_at`` to decide *whether* to run at all.

    Not scoped by ``user_id``: a connection's own id already scopes it to one
    user (``connections.user_id``), and the caller (the scheduler) already
    holds a connection it fetched user-scoped.

    Parameters
    ----------
    session : Session
        Active database session.
    connection_id : UUID
        The connection to count runs for.
    since : datetime
        Only runs with ``started_at >= since`` count.

    Returns
    -------
    int
        How many runs are on record for this connection since ``since``.
    """
    return (
        session.scalars(
            select(func.count(SyncRunRow.id)).where(
                SyncRunRow.connection_id == connection_id,
                SyncRunRow.started_at >= since,
            )
        ).one()
        or 0
    )


def oldest_recent_sync_run_started_at(
    session: Session, *, connection_id: UUID, since: datetime
) -> datetime | None:
    """Return the earliest ``started_at`` among a connection's runs since ``since``.

    The read side of "when does the background budget next free a slot" —
    once this run ages past the rolling window, the count
    :func:`count_recent_sync_runs` returns for the same ``since`` drops by
    one (assuming no newer run has landed since — an estimate, not a
    promise). See :func:`~traccio.domain.sync_schedule.next_sync_eligible_at`.

    Not scoped by ``user_id``, for the same reason as
    :func:`count_recent_sync_runs`.

    Parameters
    ----------
    session : Session
        Active database session.
    connection_id : UUID
        The connection to look at.
    since : datetime
        Only runs with ``started_at >= since`` are considered.

    Returns
    -------
    datetime or None
        The earliest ``started_at`` in the window, or ``None`` if there are
        no runs in it.
    """
    return session.scalars(
        select(func.min(SyncRunRow.started_at)).where(
            SyncRunRow.connection_id == connection_id,
            SyncRunRow.started_at >= since,
        )
    ).one()


def list_sync_runs(
    session: Session, *, user_id: UUID, connection_id: UUID | None = None, limit: int = 50
) -> list[SyncRun]:
    """Return sync runs, most recent first, for debugging and verification.

    Scoped by ``user_id``; ``connection_id`` narrows to one connection when
    given.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose runs to return; the query is scoped to it.
    connection_id : UUID or None, optional
        When given, restrict to this connection (still scoped by ``user_id``).
    limit : int, optional
        Maximum number of rows to return.

    Returns
    -------
    list[SyncRun]
        Domain sync runs (empty if none), most recent first.
    """
    query = select(SyncRunRow).where(SyncRunRow.user_id == user_id)
    if connection_id is not None:
        query = query.where(SyncRunRow.connection_id == connection_id)
    query = query.order_by(SyncRunRow.started_at.desc(), SyncRunRow.id).limit(limit)
    rows = session.scalars(query).all()
    return [row_to_sync_run(row) for row in rows]


# --- FX rates cache (ADR 0021) -------------------------------------------------
#
# The one group of queries not scoped by ``user_id``: ECB reference rates are
# public and identical for every user (``docs/domain.md``'s stated exception,
# same as seeded ``Category`` templates).


def _row_to_fx_rate(row: FxRateRow) -> FxRate:
    """Translate an :class:`FxRateRow` into a domain :class:`FxRate`.

    Parses the exact-decimal-string ``rate`` column into :class:`Decimal`, and
    treats a naive ``fetched_at`` (SQLite drops tzinfo) as UTC.
    """
    fetched_at = row.fetched_at
    if fetched_at.tzinfo is None:
        fetched_at = fetched_at.replace(tzinfo=UTC)
    return FxRate(
        base=row.base,
        quote=row.quote,
        rate_date=row.rate_date,
        rate=Decimal(row.rate),
        fetched_at=fetched_at,
    )


def get_fx_rates(
    session: Session, *, base: str, quotes: Sequence[str], up_to: date
) -> list[FxRate]:
    """Return every cached rate for ``base`` from any of ``quotes``, dated ``<= up_to``.

    Ordered by ``(quote, rate_date)`` so a caller can walk each currency's
    history and pick "the rate on or before date D".

    Parameters
    ----------
    session : Session
        Active database session.
    base : str
        The currency rates convert into.
    quotes : Sequence[str]
        The currencies to include (rates convert *from* these).
    up_to : date
        Inclusive upper bound on ``rate_date``.

    Returns
    -------
    list[FxRate]
        Cached rates, ``(quote, rate_date)`` ascending. Empty if none.
    """
    if not quotes:
        return []
    rows = session.scalars(
        select(FxRateRow)
        .where(
            FxRateRow.base == base,
            FxRateRow.quote.in_(list(quotes)),
            FxRateRow.rate_date <= up_to,
        )
        .order_by(FxRateRow.quote, FxRateRow.rate_date)
    ).all()
    return [_row_to_fx_rate(row) for row in rows]


def latest_fx_rate_fetched_at(session: Session, *, base: str, quote: str) -> datetime | None:
    """Return ``fetched_at`` of the most recent cached ``rate_date`` for a pair.

    Used to decide whether the current-day row is stale enough to re-fetch
    (``Settings.fx_rate_ttl_hours``). ``None`` when the pair is not cached at
    all.
    """
    row = session.scalars(
        select(FxRateRow)
        .where(FxRateRow.base == base, FxRateRow.quote == quote)
        .order_by(FxRateRow.rate_date.desc())
        .limit(1)
    ).one_or_none()
    if row is None:
        return None
    fetched_at = row.fetched_at
    return fetched_at if fetched_at.tzinfo is not None else fetched_at.replace(tzinfo=UTC)


def upsert_fx_rates(session: Session, *, rates: Sequence[FxRate]) -> None:
    """Insert new cached rates, refreshing ``rate``/``fetched_at`` on a re-fetch.

    Idempotent on ``(base, quote, rate_date)`` via read-then-write (no
    dialect-specific upsert), matching :func:`upsert_account`. Historical rows
    are normally written once; the most recent ``rate_date`` may be re-fetched
    (its published value can still change until it is final), so an existing
    row's ``rate`` and ``fetched_at`` are updated. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    rates : Sequence[FxRate]
        The rates to persist. ``rate`` is stored as its exact decimal string.
    """
    for fx in rates:
        existing = session.scalars(
            select(FxRateRow).where(
                FxRateRow.base == fx.base,
                FxRateRow.quote == fx.quote,
                FxRateRow.rate_date == fx.rate_date,
            )
        ).one_or_none()
        if existing is None:
            session.add(
                FxRateRow(
                    id=uuid4(),
                    base=fx.base,
                    quote=fx.quote,
                    rate_date=fx.rate_date,
                    rate=str(fx.rate),
                    fetched_at=fx.fetched_at,
                )
            )
        else:
            existing.rate = str(fx.rate)
            existing.fetched_at = fx.fetched_at
