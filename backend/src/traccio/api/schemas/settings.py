"""Request and response schemas for the per-user settings endpoints
(ADR 0024, ADR 0029).

Two settings so far: ``tracking_start_date`` — the first day the user wants
counted on the dashboard and in the Movimenti list, a whole-day calendar
boundary that clearing or raising never deletes a row, only hides it (bank
history is not re-fetchable, so a delete would be unrecoverable) — and
``meal_vouchers_enabled`` — whether the dashboard breaks meal-voucher
spending out of its headline totals (ADR 0029).
"""

from datetime import date
from uuid import UUID

from pydantic import BaseModel


class SettingsResponse(BaseModel):
    """The user's current settings.

    Attributes
    ----------
    tracking_start_date : date or None
        The stored floor, or ``None`` for "no floor — show everything".
    meal_vouchers_enabled : bool
        Whether the dashboard's "Buoni pasto" breakout is on.
    """

    tracking_start_date: date | None
    meal_vouchers_enabled: bool


class SetMealVouchersRequest(BaseModel):
    """Body for ``POST /settings/meal-vouchers``.

    A separate endpoint from ``POST /settings`` rather than a second field on
    :class:`SetTrackingStartRequest`: that body is deliberately
    mandatory-but-nullable so "clear the date" is never ambiguous with "leave
    it alone", and a plain optional boolean would reintroduce exactly that
    ambiguity for this setting.

    Attributes
    ----------
    enabled : bool
        The new state.
    """

    enabled: bool


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
