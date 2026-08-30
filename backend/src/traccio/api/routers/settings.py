"""Per-user settings endpoints (ADR 0024).

The first per-user setting in Traccio: ``tracking_start_date``, the day the
dashboard and the Movimenti list begin from. Months before it show only the
accounts that happened to be connected earliest, so their totals mislead —
this lets the user start clean from a month every account covers.

- ``GET /settings`` returns the current value.
- ``POST /settings`` sets or clears it (mandatory-but-nullable body).
- ``GET /settings/tracking-start/suggestion`` computes a suggested value from
  each account's first movement, and names the account that constrains it.

Data safety (``.claude/rules/data-safety.md``): these handlers log only dates
and counts — never an amount or a description.
"""

from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.settings import (
    AccountEarliestResponse,
    SetTrackingStartRequest,
    TrackingStartResponse,
    TrackingStartSuggestionResponse,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    earliest_transaction_dates_by_account,
    get_tracking_start_date,
    list_accounts,
    set_tracking_start_date,
)
from traccio.db.session import get_session
from traccio.domain.accounts import display_name
from traccio.domain.tracking import suggest_tracking_start

logger = get_logger(__name__)

router = APIRouter()


@router.get("/settings", response_model=TrackingStartResponse)
def get_settings_endpoint(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TrackingStartResponse:
    """Return the current user's settings.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose settings to read.

    Returns
    -------
    TrackingStartResponse
        The stored ``tracking_start_date``, or ``null``.
    """
    return TrackingStartResponse(
        tracking_start_date=get_tracking_start_date(session, user_id=user_id)
    )


@router.post("/settings", response_model=TrackingStartResponse)
def set_settings_endpoint(
    body: SetTrackingStartRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TrackingStartResponse:
    """Set or clear the current user's tracking start date.

    Reversible: raising or clearing the date never deletes a movement, it only
    changes which ones the dashboard and Movimenti show. Scoped to the current
    user.

    Parameters
    ----------
    body : SetTrackingStartRequest
        The new ``tracking_start_date`` (``null`` to clear).
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose settings to write.

    Returns
    -------
    TrackingStartResponse
        The value now stored.
    """
    set_tracking_start_date(session, user_id=user_id, value=body.tracking_start_date)
    session.commit()
    logger.info("settings.set_tracking_start", cleared=body.tracking_start_date is None)
    return TrackingStartResponse(tracking_start_date=body.tracking_start_date)


@router.get(
    "/settings/tracking-start/suggestion",
    response_model=TrackingStartSuggestionResponse,
)
def tracking_start_suggestion_endpoint(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TrackingStartSuggestionResponse:
    """Suggest a tracking start from each account's first movement.

    The suggestion is the first day of the earliest month every account fully
    covers; the constraining account is the one whose first movement is the
    latest. Accounts with no dated movement are listed too (``earliest:
    null``) — they place no constraint, but the user should see they exist.
    Scoped to the current user.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose accounts to scan.

    Returns
    -------
    TrackingStartSuggestionResponse
        The suggested date, the constraining account, and every account's
        first-movement date.
    """
    accounts = list_accounts(session, user_id)
    earliest_by_account = earliest_transaction_dates_by_account(session, user_id=user_id)

    suggestion = suggest_tracking_start(earliest_by_account)
    constraining_account_id: UUID | None = None
    if earliest_by_account:
        latest = max(earliest_by_account.values())
        constraining_account_id = next(
            account_id for account_id, earliest in earliest_by_account.items() if earliest == latest
        )

    rows = [
        AccountEarliestResponse(
            account_id=account.id,
            display_name=display_name(account),
            earliest=earliest_by_account.get(account.id),
        )
        for account in accounts
    ]
    # Earliest-movement first; accounts with none sink to the bottom; then by
    # display name for a stable order.
    rows.sort(key=lambda r: (r.earliest is None, r.earliest or date.min, r.display_name or ""))

    logger.info(
        "settings.tracking_start_suggestion",
        accounts=len(rows),
        has_suggestion=suggestion is not None,
    )
    return TrackingStartSuggestionResponse(
        suggestion=suggestion,
        constraining_account_id=constraining_account_id,
        accounts=rows,
    )
