"""Accounts endpoint router."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.accounts import AccountResponse, AccountsResponse
from traccio.core.logging import get_logger
from traccio.db.repositories import list_accounts
from traccio.db.session import get_session

logger = get_logger(__name__)

router = APIRouter()


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
