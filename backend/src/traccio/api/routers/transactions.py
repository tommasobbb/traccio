"""Transactions endpoint router.

Also carries the category-confirming endpoints
(``POST``/``DELETE /transactions/{id}/category``): the path prefix owns the
router, the same rule that puts ``/events/{id}/transactions`` on the events
router rather than here (see ``api/routers/events.py``).
"""

from datetime import UTC, date, datetime, timedelta
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_tracking_start, current_user_id
from traccio.api.schemas.transactions import (
    ConfirmCategoryRequest,
    CreateManualTransactionRequest,
    EditManualTransactionRequest,
    PrunePendingResponse,
    TransactionResponse,
    TransactionsResponse,
)
from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    create_manual_transaction,
    delete_manual_transaction,
    event_ids_for_transactions,
    get_account,
    get_category,
    get_transaction,
    get_transaction_event_id,
    list_child_category_ids,
    list_transactions,
    prune_stale_pending_transactions,
    set_confirmed_category,
    transaction_is_linked,
    update_manual_transaction,
)
from traccio.db.session import get_session
from traccio.domain.accounts import account_source
from traccio.domain.enums import (
    AccountSource,
    KeyStrategy,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.models import Transaction
from traccio.domain.money import Money
from traccio.domain.search import MAX_SEARCH_TERM_LENGTH, normalize_search_term
from traccio.services.advance_shares import resolve_advance_shares

logger = get_logger(__name__)

router = APIRouter()


@router.get("/transactions", response_model=TransactionsResponse)
def transactions(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    account_id: Annotated[UUID | None, Query()] = None,
    event_id: Annotated[UUID | None, Query()] = None,
    category_id: Annotated[UUID | None, Query()] = None,
    uncategorized: Annotated[bool, Query()] = False,
    q: Annotated[str | None, Query()] = None,
    start: Annotated[datetime | None, Query()] = None,
    end: Annotated[datetime | None, Query()] = None,
    tracking_start: Annotated[date | None, Depends(current_tracking_start)] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> TransactionsResponse:
    """List the current user's transactions, most recent first.

    Scoped to the current user (see :func:`~traccio.api.deps.current_user_id`);
    the underlying query is already ``scoped by user_id``. Every optional
    filter is always combined with ``user_id``, so none can reach another
    user's rows. ``limit``/``offset`` page the result.

    Parameters
    ----------
    session : Session
        Request-scoped database session (see :func:`get_session`).
    user_id : UUID
        The user whose transactions to return.
    account_id : UUID or None, optional
        When given, restrict to this account.
    event_id : UUID or None, optional
        When given, restrict to transactions grouped under this event.
    category_id : UUID or None, optional
        When given, restrict to transactions whose effective category is this
        one — or, if it names a root category, one of its children too (a
        two-level rollup, so a Panoramica drill-down through a root shows
        every transaction the chart above it counted). Mutually exclusive
        with ``uncategorized`` — combining both is a ``422``.
    uncategorized : bool, optional
        When true, restrict to transactions with no effective category.
        Mutually exclusive with ``category_id``.
    q : str or None, optional
        Free-text search term, matched case-insensitively against
        ``description`` or the cleaned-up ``display_description``. Blank or
        whitespace-only is treated as absent. Longer than
        :data:`~traccio.domain.search.MAX_SEARCH_TERM_LENGTH` is a ``422``.
        Never logged — it is counterparty text
        (``docs/engineering.md``).
    start : datetime or None, optional
        Inclusive lower bound on ``coalesce(booked_at, value_date)``.
    end : datetime or None, optional
        Exclusive upper bound on the same expression (half-open ``[start,
        end)``), the same period semantics as ``GET /dashboard/summary``.
    tracking_start : date or None
        Not a query param — the user's stored ``tracking_start_date`` floor
        (ADR 0024), injected via :func:`~traccio.api.deps.current_tracking_start`.
        Rows before it are hidden (a dateless row too, like any lower bound).
        Reversible: it is changed through ``/settings``, never a delete.
    limit : int, optional
        Page size, between 1 and 200 (default 50).
    offset : int, optional
        Number of rows to skip (default 0).

    Returns
    -------
    TransactionsResponse
        The requested page of the user's transactions, most recent first.
    """
    if category_id is not None and uncategorized:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="conflicting_category_filter"
        )
    search_term = normalize_search_term(q)
    if search_term is not None and len(search_term) > MAX_SEARCH_TERM_LENGTH:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="search_too_long"
        )
    category_ids: list[UUID] | None = None
    if category_id is not None:
        # Expand a root into itself + its children (a no-op list if
        # category_id names a child, or an unknown/foreign id) — see
        # list_transactions's own docstring for why this is a plural filter.
        category_ids = [
            category_id,
            *list_child_category_ids(session, user_id=user_id, category_id=category_id),
        ]
    found = list_transactions(
        session,
        user_id,
        account_id=account_id,
        event_id=event_id,
        category_ids=category_ids,
        uncategorized=uncategorized,
        q=search_term,
        start=start,
        end=end,
        tracking_start=tracking_start,
        limit=limit,
        offset=offset,
    )
    # An advance transaction's effective_amount is its derived spending share,
    # which depends on the declared own_share, the reimbursements received, and
    # whether the advance was written off (a write-off moves the outstanding
    # amount into spending). Resolved once per row (role=advance is only ever
    # set alongside an Advance row, so the map is always consistent).
    shares = resolve_advance_shares(session, user_id=user_id, transactions=found)
    event_by_tx = event_ids_for_transactions(
        session, user_id=user_id, transaction_ids=[transaction.id for transaction in found]
    )

    responses = [
        TransactionResponse.from_domain(
            transaction,
            advance_own_share=shares.get(transaction.id),
            event_id=event_by_tx.get(transaction.id),
        )
        for transaction in found
    ]

    # Log a count, never transaction contents (see data-safety rules).
    logger.info("transactions.list", count=len(responses))
    return TransactionsResponse(transactions=responses)


@router.get("/transactions/{transaction_id}", response_model=TransactionResponse)
def transaction(
    transaction_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransactionResponse:
    """Return one of the current user's transactions.

    Scoped to the current user; a ``404`` if the transaction is unknown or not
    the caller's — the same cross-user gate the category endpoints below use.
    Exists so a client can re-fetch a single row's server-derived
    ``effective_amount``/``effective_category_id`` after a write (e.g.
    confirming a category) without re-paginating the whole list.

    Parameters
    ----------
    transaction_id : UUID
        The transaction to fetch.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transaction belongs to.

    Returns
    -------
    TransactionResponse
        The transaction, with the same derived fields ``GET /transactions``
        returns for the same row.
    """
    found = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if found is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown transaction")

    # Mirrors the list endpoint's advance-share resolution above, scoped to one
    # row: an advance transaction's effective_amount depends on its own_share,
    # reimbursements received, and write-off state, all resolved the same way.
    advance_own_share = None
    if found.role == TransactionRole.ADVANCE:
        shares = resolve_advance_shares(session, user_id=user_id, transactions=[found])
        advance_own_share = shares.get(found.id)
    event_id = get_transaction_event_id(session, user_id=user_id, transaction_id=found.id)

    logger.info("transactions.get", transaction_id=str(transaction_id))
    return TransactionResponse.from_domain(
        found, advance_own_share=advance_own_share, event_id=event_id
    )


@router.post(
    "/transactions", response_model=TransactionResponse, status_code=status.HTTP_201_CREATED
)
def create_manual_transaction_endpoint(
    body: CreateManualTransactionRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransactionResponse:
    """Create a user-entered movement on a manual account (ADR 0020).

    The row is always ``booked`` with ``role=personal`` — there is no pending
    lifecycle without a bank — and its ``stable_key`` is its own id
    (``key_strategy=manual``). A ``404`` if the account (or the optional
    category) is unknown or not the caller's; a ``409 account_not_manual`` if
    the account is a synced one, whose history is bank-owned and immutable.

    Parameters
    ----------
    body : CreateManualTransactionRequest
        The movement's account, amount, currency, value date, description, and
        optional category.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the account and movement belong to.

    Returns
    -------
    TransactionResponse
        The newly created transaction, with the same derived fields
        ``GET /transactions`` returns.
    """
    account = get_account(session, user_id=user_id, account_id=body.account_id)
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown account")
    if account_source(account) is not AccountSource.MANUAL:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="account_not_manual")
    if body.confirmed_category_id is not None:
        category = get_category(session, user_id=user_id, category_id=body.confirmed_category_id)
        if category is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown category")

    new_id = uuid4()
    transaction = Transaction(
        id=new_id,
        user_id=user_id,
        account_id=body.account_id,
        money=Money(amount=body.amount, currency=body.currency),
        booked_at=None,
        value_date=body.value_date,
        description=body.description,
        status=TransactionStatus.BOOKED,
        role=TransactionRole.PERSONAL,
        stable_key=str(new_id),
        key_strategy=KeyStrategy.MANUAL,
    )
    created = create_manual_transaction(
        session, transaction=transaction, confirmed_category_id=body.confirmed_category_id
    )
    session.commit()
    logger.info("transactions.create_manual", transaction_id=str(created.id))
    return TransactionResponse.from_domain(created)


@router.post("/transactions/{transaction_id}/edit", response_model=TransactionResponse)
def edit_manual_transaction_endpoint(
    transaction_id: UUID,
    body: EditManualTransactionRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransactionResponse:
    """Edit a user-entered movement on a manual account (ADR 0020).

    Changes only the four movement fields (amount, currency, value date,
    description); identity, status, role, and category are untouched. A
    ``404`` if the transaction is unknown or not the caller's; a ``409
    transaction_not_manual`` if it is on a synced account, where a movement is
    bank-owned and immutable (corrections arrive as new transactions).

    Parameters
    ----------
    transaction_id : UUID
        The transaction to edit.
    body : EditManualTransactionRequest
        The new movement fields.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transaction belongs to.

    Returns
    -------
    TransactionResponse
        The transaction after the edit.
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown transaction")
    account = get_account(session, user_id=user_id, account_id=transaction.account_id)
    if account is None or account_source(account) is not AccountSource.MANUAL:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="transaction_not_manual")

    update_manual_transaction(
        session,
        user_id=user_id,
        transaction_id=transaction_id,
        amount=body.amount,
        currency=body.currency,
        value_date=body.value_date,
        description=body.description,
    )
    session.commit()
    logger.info("transactions.edit_manual", transaction_id=str(transaction_id))
    edited = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if edited is None:  # pragma: no cover - just deleted under us
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown transaction")
    return TransactionResponse.from_domain(edited)


@router.delete("/transactions/{transaction_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_manual_transaction_endpoint(
    transaction_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete a user-entered movement on a manual account (ADR 0020).

    A ``404`` if the transaction is unknown or not the caller's. A ``409
    transaction_not_manual`` if it is on a synced account. A ``409
    transaction_in_use`` if it is a leg of a transfer, or an advance's or
    reimbursement's transaction — unlink that first, the same
    refuse-rather-than-cascade stance as ``409 category_in_use``.

    Parameters
    ----------
    transaction_id : UUID
        The transaction to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transaction belongs to.
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown transaction")
    account = get_account(session, user_id=user_id, account_id=transaction.account_id)
    if account is None or account_source(account) is not AccountSource.MANUAL:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="transaction_not_manual")
    if transaction_is_linked(session, user_id=user_id, transaction_id=transaction_id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="transaction_in_use")

    delete_manual_transaction(session, user_id=user_id, transaction_id=transaction_id)
    session.commit()
    logger.info("transactions.delete_manual", transaction_id=str(transaction_id))


@router.post("/transactions/{transaction_id}/category", status_code=status.HTTP_204_NO_CONTENT)
def confirm_transaction_category(
    transaction_id: UUID,
    body: ConfirmCategoryRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Confirm a category on a transaction — the explicit user action.

    Sets ``confirmed_category_id`` via
    :func:`~traccio.db.repositories.set_confirmed_category` — the only writer
    of that column — which then wins over any suggestion in the derived
    ``effective_category_id`` (see
    :func:`~traccio.domain.categories.effective_category`). A ``404`` if the
    transaction or the category is unknown or not the caller's — a stranger's
    category id is indistinguishable from an unknown one, so this doubles as
    the cross-user gate.

    Parameters
    ----------
    transaction_id : UUID
        The transaction to categorize.
    body : ConfirmCategoryRequest
        The category to confirm.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user both the transaction and category belong to.
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown transaction")
    category = get_category(session, user_id=user_id, category_id=body.category_id)
    if category is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown category")

    set_confirmed_category(
        session, user_id=user_id, transaction_id=transaction_id, category_id=body.category_id
    )
    session.commit()
    logger.info("transactions.confirm_category", transaction_id=str(transaction_id))


@router.delete("/transactions/{transaction_id}/category", status_code=status.HTTP_204_NO_CONTENT)
def clear_transaction_category(
    transaction_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Clear a transaction's confirmed category, falling back to any suggestion.

    Idempotent: clearing when nothing is confirmed still succeeds (a ``409`` is
    never raised for "already clear"). A ``404`` if the transaction is unknown
    or not the caller's.

    Parameters
    ----------
    transaction_id : UUID
        The transaction to clear.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the transaction belongs to.
    """
    transaction = get_transaction(session, user_id=user_id, transaction_id=transaction_id)
    if transaction is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown transaction")

    set_confirmed_category(
        session, user_id=user_id, transaction_id=transaction_id, category_id=None
    )
    session.commit()
    logger.info("transactions.clear_category", transaction_id=str(transaction_id))


@router.post("/transactions/prune-pending", response_model=PrunePendingResponse)
def prune_pending_transactions(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> PrunePendingResponse:
    """Delete abandoned pending transactions, per ``docs/domain.md``.

    "Pending transactions that neither settle nor reappear within a defined
    window are dropped, not kept as ghosts." Explicit and on-demand — like
    ``POST /rules/apply`` (ADR 0005) — rather than wired into sync, until a
    background scheduler (M3) makes that worth the added write path inside
    sync. Never touches a row the user has acted on: see
    :func:`~traccio.db.repositories.prune_stale_pending_transactions` for the
    full eligibility rule (still ``pending``, unseen by a sync for
    ``Settings.pending_transaction_ttl_days``, still ``personal``, not in an
    event, no confirmed category).

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose pending transactions to prune.

    Returns
    -------
    PrunePendingResponse
        How many rows were deleted.
    """
    cutoff = datetime.now(UTC) - timedelta(days=get_settings().pending_transaction_ttl_days)
    pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=cutoff)
    session.commit()

    # Log a count, never row contents (see data-safety rules).
    logger.info("transactions.prune_pending", pruned=pruned)
    return PrunePendingResponse(pruned=pruned)
