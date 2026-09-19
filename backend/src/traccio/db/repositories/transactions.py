"""Transaction queries: sync upserts, reads and period slices, manual CRUD,
and the role / category writes that mutate a ``TransactionRow``."""

from collections.abc import Mapping, Sequence
from datetime import date, datetime
from typing import TYPE_CHECKING, Any, cast
from uuid import UUID

from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    from sqlalchemy import CursorResult

from traccio.db.mappers import (
    row_to_transaction,
    transaction_to_row,
)
from traccio.db.models import (
    AdvanceRow,
    ReimbursementRow,
    TransactionRow,
    TransferDismissalRow,
    TransferRow,
)
from traccio.db.repositories._common import _tracking_floor, _transaction_when
from traccio.domain.enums import (
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.models import (
    Transaction,
)
from traccio.domain.search import escape_like


def upsert_transaction(session: Session, *, transaction: Transaction, now: datetime) -> Transaction:
    """Insert a transaction or update a still-pending one in place.

    Idempotent on ``(account_id, stable_key)`` — the unique constraint that makes
    a re-sync change nothing (``docs/architecture.md``). Read-then-write (no
    dialect-specific upsert) so it behaves the same on SQLite and PostgreSQL. The
    caller owns the transaction boundary and commits.

    The match is also scoped by ``user_id`` — root ``docs/engineering.md``'s "every query
    is scoped by ``user_id``, no exceptions" applies here too, even though
    ``account_id`` alone is already user-unique (an account belongs to exactly
    one user, like :func:`~traccio.db.repositories.upsert_account`'s own
    ``user_id`` scoping on ``identification_hash``): defense in depth costs
    nothing on an indexed column.

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
            TransactionRow.user_id == transaction.user_id,
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
    # rowcount. Cast at this one edge, per docs/engineering.md.
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


def list_all_transactions(
    session: Session, user_id: UUID, *, since: date | None = None
) -> list[Transaction]:
    """Return every one of the user's transactions, most recent first.

    Scoped by ``user_id``. Unlike :func:`list_transactions` this is unpaginated:
    it feeds in-memory detection (e.g. transfer suggestions), which must see the
    whole pool to pair legs, not one page. Ordering matches the paginated reader
    for consistency but detection does not depend on it.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transactions to return; the query is scoped to it.
    since : date or None, optional
        When given, drop rows whose ``coalesce(booked_at, value_date)`` is
        before UTC midnight of that day — the same
        :func:`_tracking_floor` bound :func:`list_transactions` applies (ADR
        0024). Transfer suggestions pass the user's ``tracking_start_date`` so
        detection does not scan the partial-coverage history that setting
        exists to hide (ADR 0025); rule application passes nothing, since a
        rule categorizes every row regardless of the floor.

    Returns
    -------
    list[Transaction]
        The matching domain transactions owned by ``user_id`` (empty if none),
        newest first.
    """
    statement = select(TransactionRow).where(TransactionRow.user_id == user_id)
    floor = _tracking_floor(since)
    if floor is not None:
        statement = statement.where(_transaction_when() >= floor)
    rows = session.scalars(statement.order_by(_transaction_when().desc(), TransactionRow.id)).all()
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
    tracking_start: date | None = None,
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
    floor = _tracking_floor(tracking_start)
    if floor is not None:
        query = query.where(when >= floor)
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


def list_transactions_by_ids(
    session: Session, *, user_id: UUID, ids: Sequence[UUID]
) -> dict[UUID, Transaction]:
    """Return the transactions among ``ids`` that belong to ``user_id``, keyed by id.

    One query for however many ids are asked for, in place of calling
    :func:`get_transaction` once per id — the batch form a caller resolving a
    whole page of rows (e.g. every advance's linked transaction) needs to
    avoid an N+1. An id not owned by ``user_id``, or unknown, is simply absent
    from the result rather than raising.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner the ids are scoped to.
    ids : Sequence[UUID]
        The transaction ids to fetch. An empty sequence short-circuits to an
        empty result with no query.

    Returns
    -------
    dict[UUID, Transaction]
        Each found transaction, keyed by its id.
    """
    if not ids:
        return {}
    rows = session.scalars(
        select(TransactionRow).where(
            TransactionRow.id.in_(ids),
            TransactionRow.user_id == user_id,
        )
    ).all()
    return {row.id: row_to_transaction(row) for row in rows}


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
