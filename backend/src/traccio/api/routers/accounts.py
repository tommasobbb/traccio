"""Accounts endpoint router.

Action-style endpoints, no PATCH (same as the categories router): ``rename``
sets or clears the user-chosen alias, ``appearance`` sets the colour and icon
together. ``POST /accounts`` creates a **manual** account (ADR 0020) — one
with no bank connection — and ``DELETE /accounts/{id}`` removes an empty one;
a synced account is created and removed only by the sync/connection flow.
Data safety (``.claude/rules/data-safety.md``): these handlers log only ids
and counts — never an alias, which is user-typed text.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.accounts import (
    AccountResponse,
    AccountsResponse,
    CreateManualAccountRequest,
    RenameAccountRequest,
    SetAccountAppearanceRequest,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    account_has_transactions,
    create_manual_account,
    delete_manual_account,
    get_account,
    list_accounts,
    set_account_alias,
    set_account_appearance,
)
from traccio.db.session import get_session
from traccio.domain.accounts import (
    AccountError,
    account_source,
    normalize_account_alias,
)
from traccio.domain.enums import AccountSource
from traccio.domain.models import Account

logger = get_logger(__name__)

router = APIRouter()


def _load_account(session: Session, *, user_id: UUID, account_id: UUID) -> Account:
    """Load an account owned by the user, or raise ``404``.

    Scoping is enforced by :func:`~traccio.db.repositories.get_account`, so
    naming another user's (or an unknown) account is indistinguishable from
    "not found".
    """
    account = get_account(session, user_id=user_id, account_id=account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="unknown account")
    return account


@router.get("/accounts", response_model=AccountsResponse)
def accounts(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AccountsResponse:
    """List the current user's accounts.

    Scoped to the current user (see :func:`~traccio.api.deps.current_user_id`).
    The query itself is already written ``scoped by user_id``; only the source
    of the id changes when auth arrives.

    Parameters
    ----------
    session : Session
        Request-scoped database session (see :func:`get_session`).
    user_id : UUID
        The user whose accounts to return.

    Returns
    -------
    AccountsResponse
        The user's accounts, oldest first.
    """
    found = list_accounts(session, user_id)
    # Log a count, never account contents (see data-safety rules).
    logger.info("accounts.list", count=len(found))
    return AccountsResponse(accounts=[AccountResponse.from_domain(account) for account in found])


@router.post("/accounts", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_manual_account_endpoint(
    body: CreateManualAccountRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AccountResponse:
    """Create a manual account — one with no bank connection (ADR 0020).

    For hand-tracked money: a cash float, an investment pass-through. The
    account has ``connection_id`` and ``identification_hash`` both ``None``, so
    a sync can never touch it, and its ``source`` is ``manual``. A ``422`` if
    the alias is blank or too long, or the currency/kind is not a recognized
    value.

    Parameters
    ----------
    body : CreateManualAccountRequest
        The new account's name, kind, currency, and optional appearance.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the account belongs to.

    Returns
    -------
    AccountResponse
        The newly created manual account.
    """
    try:
        alias = normalize_account_alias(body.alias)
    except AccountError as exc:
        raise HTTPException(status_code=422, detail=exc.reason) from exc
    # normalize_account_alias only returns None for a None input; the schema
    # types alias as a required str, so a blank one already raised above.
    account = Account(
        user_id=user_id,
        kind=body.kind,
        currency=body.currency,
        alias=alias,
        color=body.color,
        icon=body.icon,
    )
    created = create_manual_account(session, account=account)
    session.commit()
    logger.info("accounts.create_manual", account_id=str(created.id))
    return AccountResponse.from_domain(created)


@router.post("/accounts/{account_id}/rename", response_model=AccountResponse)
def rename_account_endpoint(
    account_id: UUID,
    body: RenameAccountRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AccountResponse:
    """Set or clear an account's alias.

    A ``404`` if the account is unknown or not the caller's; a ``422`` if the
    alias is blank (use ``null`` to clear it) or too long.

    Parameters
    ----------
    account_id : UUID
        The account to rename.
    body : RenameAccountRequest
        The new alias, or ``null`` to clear it.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the account belongs to.

    Returns
    -------
    AccountResponse
        The account under its new alias.
    """
    _load_account(session, user_id=user_id, account_id=account_id)
    try:
        alias = normalize_account_alias(body.alias)
    except AccountError as exc:
        raise HTTPException(status_code=422, detail=exc.reason) from exc

    set_account_alias(session, user_id=user_id, account_id=account_id, alias=alias)
    session.commit()
    logger.info("accounts.rename", account_id=str(account_id))
    updated = _load_account(session, user_id=user_id, account_id=account_id)
    return AccountResponse.from_domain(updated)


@router.post("/accounts/{account_id}/appearance", response_model=AccountResponse)
def set_account_appearance_endpoint(
    account_id: UUID,
    body: SetAccountAppearanceRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> AccountResponse:
    """Set an account's colour and icon.

    A full replace: both fields are applied together. A ``404`` if the
    account is unknown or not the caller's; an unrecognized value is
    rejected by request validation before the handler runs (``422``).

    Parameters
    ----------
    account_id : UUID
        The account to restyle.
    body : SetAccountAppearanceRequest
        The new colour and icon.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the account belongs to.

    Returns
    -------
    AccountResponse
        The account under its new appearance.
    """
    _load_account(session, user_id=user_id, account_id=account_id)
    set_account_appearance(
        session, user_id=user_id, account_id=account_id, color=body.color, icon=body.icon
    )
    session.commit()
    logger.info("accounts.appearance", account_id=str(account_id))
    updated = _load_account(session, user_id=user_id, account_id=account_id)
    return AccountResponse.from_domain(updated)


@router.delete("/accounts/{account_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_manual_account_endpoint(
    account_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete a manual account (ADR 0020).

    A ``404`` if the account is unknown or not the caller's. A ``409
    account_not_manual`` if it is a synced account — those are removed only by
    the connection flow, never here. A ``409 account_not_empty`` if it still
    holds any transaction: the account's movements must be deleted first
    (``DELETE /transactions/{id}``), mirroring ``409 category_in_use`` —
    financial data is never cascade-deleted out from under the user.

    Parameters
    ----------
    account_id : UUID
        The account to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the account belongs to.
    """
    account = _load_account(session, user_id=user_id, account_id=account_id)
    if account_source(account) is not AccountSource.MANUAL:
        raise HTTPException(status_code=409, detail="account_not_manual")
    if account_has_transactions(session, user_id=user_id, account_id=account_id):
        raise HTTPException(status_code=409, detail="account_not_empty")

    delete_manual_account(session, user_id=user_id, account_id=account_id)
    session.commit()
    logger.info("accounts.delete_manual", account_id=str(account_id))
