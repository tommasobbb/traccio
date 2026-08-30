"""Request and response schemas for the per-user settings endpoints (ADR 0024).

The only setting so far is ``tracking_start_date`` — the first day the user
wants counted on the dashboard and in the Movimenti list. It is a whole-day
calendar boundary, and clearing or raising it never deletes a row, only hides
it (bank history is not re-fetchable, so a delete would be unrecoverable).
"""

from datetime import date
from uuid import UUID

from pydantic import BaseModel


class TrackingStartResponse(BaseModel):
    """The user's current tracking start date.

    Attributes
    ----------
    tracking_start_date : date or None
        The stored floor, or ``None`` for "no floor — show everything".
    """

    tracking_start_date: date | None


class SetTrackingStartRequest(BaseModel):
    """Body for ``POST /settings``.

    ``tracking_start_date`` is **mandatory but nullable**: the key must be
    present so "clear it" (``null``) is never ambiguous with "leave it alone"
    (key omitted). Same posture as ``POST /accounts/{id}/rename`` (ADR 0017).

    Attributes
    ----------
    tracking_start_date : date or None
        The new floor, or ``null`` to clear it.
    """

    tracking_start_date: date | None


class AccountEarliestResponse(BaseModel):
    """One account and the date of its earliest movement.

    Attributes
    ----------
    account_id : UUID
        The account.
    display_name : str or None
        Its resolved display name (alias, else provider name, else ``None``).
    earliest : date or None
        The date of its first dated movement, or ``None`` when it has no
        movements (or only dateless ones) — such an account places no
        constraint on the suggestion.
    """

    account_id: UUID
    display_name: str | None
    earliest: date | None


class TrackingStartSuggestionResponse(BaseModel):
    """A suggested tracking start plus the per-account dates it is derived from.

    Attributes
    ----------
    suggestion : date or None
        The first day of the earliest month every account fully covers
        (:func:`~traccio.domain.tracking.suggest_tracking_start`), or ``None``
        when no account has a dated movement yet.
    constraining_account_id : UUID or None
        The account whose first movement is the latest — the one that pushes
        the suggestion forward. ``None`` when there is nothing to suggest
        from. The client highlights it so the choice is informed.
    accounts : list[AccountEarliestResponse]
        Every account, earliest-movement first (accounts with none last),
        then by display name.
    """

    suggestion: date | None
    constraining_account_id: UUID | None
    accounts: list[AccountEarliestResponse]
