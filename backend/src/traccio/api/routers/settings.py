"""Per-user settings endpoints (ADR 0024, ADR 0029).

Two per-user settings so far: ``tracking_start_date``, the day the dashboard
and the Movimenti list begin from — months before it show only the accounts
that happened to be connected earliest, so their totals mislead, and this
lets the user start clean from a month every account covers — and
``meal_vouchers_enabled``, whether the dashboard breaks meal-voucher spending
out of its headline totals.

- ``GET /settings`` returns both current values.
- ``POST /settings`` sets or clears ``tracking_start_date``
  (mandatory-but-nullable body).
- ``POST /settings/meal-vouchers`` sets ``meal_vouchers_enabled``.
- ``GET /settings/tracking-start/suggestion`` computes a suggested tracking
  start from each account's first movement, and names the account that
  constrains it.

Data safety (``.claude/rules/data-safety.md``): these handlers log only dates,
booleans, and counts — never an amount or a description.
"""

from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.settings import (
    AccountEarliestResponse,
    SetMealVouchersRequest,
    SettingsResponse,
    SetTrackingStartRequest,
    TrackingStartSuggestionResponse,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    earliest_transaction_dates_by_account,
    get_meal_vouchers_enabled,
    get_tracking_start_date,
    list_accounts,
    set_meal_vouchers_enabled,
    set_tracking_start_date,
)
from traccio.db.session import get_session
from traccio.domain.accounts import display_name
from traccio.domain.tracking import suggest_tracking_start

logger = get_logger(__name__)

router = APIRouter()


def _current_settings(session: Session, *, user_id: UUID) -> SettingsResponse:
    """Read both current settings into one response."""
    return SettingsResponse(
        tracking_start_date=get_tracking_start_date(session, user_id=user_id),
        meal_vouchers_enabled=get_meal_vouchers_enabled(session, user_id=user_id),
    )


@router.get("/settings", response_model=SettingsResponse)
def get_settings_endpoint(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> SettingsResponse:
    """Return the current user's settings.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose settings to read.

    Returns
    -------
    SettingsResponse
        The stored ``tracking_start_date`` (or ``null``) and
        ``meal_vouchers_enabled``.
    """
    return _current_settings(session, user_id=user_id)


@router.post("/settings", response_model=SettingsResponse)
def set_settings_endpoint(
    body: SetTrackingStartRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> SettingsResponse:
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
    SettingsResponse
        Both settings, ``tracking_start_date`` now updated.
    """
    set_tracking_start_date(session, user_id=user_id, value=body.tracking_start_date)
    session.commit()
    logger.info("settings.set_tracking_start", cleared=body.tracking_start_date is None)
    return _current_settings(session, user_id=user_id)


@router.post("/settings/meal-vouchers", response_model=SettingsResponse)
def set_meal_vouchers_endpoint(
    body: SetMealVouchersRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> SettingsResponse:
    """Turn the meal-vouchers dashboard breakout on or off (ADR 0029).

    Reversible: with the setting off, a voucher-kind account behaves like any
    other account again — counted in the headline totals, listed in "Per
    conto". Scoped to the current user.

    Parameters
    ----------
    body : SetMealVouchersRequest
        The new state.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose settings to write.

    Returns
    -------
    SettingsResponse
        Both settings, ``meal_vouchers_enabled`` now updated.
    """
    set_meal_vouchers_enabled(session, user_id=user_id, value=body.enabled)
    session.commit()
    logger.info("settings.set_meal_vouchers", enabled=body.enabled)
    return _current_settings(session, user_id=user_id)


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
