"""Request and response schemas for the event endpoints.

An event groups transactions from one occasion so the user can see what it
actually cost. Its ``total`` is **derived** from the members' ``effective_amount``
by the one pure :func:`~traccio.domain.events.event_total` function, never stored
— the client renders it and never recomputes. An event has no currency of its
own: ``currency`` is the members' shared currency, ``null`` for an empty event
(whose ``total`` is ``0``).

Scope (2026-08-21): the total is a single net figure; a per-category breakdown
is a later slice. Categorization now exists (``traccio.domain.categories``),
which unblocks the breakdown in principle, but it has not shipped yet (see
``tasks/backlog.md``).
"""

from datetime import date, datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, BeforeValidator

from traccio.api.schemas.dashboard import CategoryDisplay, CategoryGroupSummaryResponse
from traccio.domain.dashboard import CurrencySummary
from traccio.domain.emoji import validate_emoji
from traccio.domain.enums import EventStatus, PaletteColor
from traccio.domain.models import Event
from traccio.domain.money import Money


def _validated_emoji(value: object) -> object:
    """Trim and validate an optional emoji, or pass ``None`` through.

    A non-``None`` value must be a single emoji
    (:func:`~traccio.domain.emoji.validate_emoji`); anything else raises,
    which pydantic surfaces as a ``422``. Non-``str`` input is left for
    pydantic's own type check to reject.
    """
    if value is None or not isinstance(value, str):
        return value
    return validate_emoji(value)


# A request emoji field: ``None`` or a validated single emoji.
EmojiField = Annotated[str | None, BeforeValidator(_validated_emoji)]


class CreateEventRequest(BaseModel):
    """Body for creating an event.

    Attributes
    ----------
    name : str
        Human-readable name for the occasion (e.g. ``"Turkey 2026"``).
    emoji : str or None
        Optional single emoji for the event's tile (ADR 0027), validated.
    color : PaletteColor or None
        Optional colour for the tile, from the shared PaletteColor vocabulary.
    start_date : date or None
        Optional first day of the occasion; a hint, not a membership rule.
    end_date : date or None
        Optional last day of the occasion.
    """

    name: str
    emoji: EmojiField = None
    color: PaletteColor | None = None
    start_date: date | None = None
    end_date: date | None = None


class UpdateEventRequest(BaseModel):
    """Body for editing an event (``POST /events/{event_id}``, ADR 0027).

    A **full replace** of the fields the client's single event editor owns:
    ``name`` (required — the editor never clears it), ``emoji``, ``color`` and
    the date range are all sent every time, ``null`` meaning "cleared". The
    event's ``status`` is not here — close/reopen has its own endpoint.

    Attributes
    ----------
    name : str
        The new name.
    emoji : str or None
        The new emoji, validated, or ``null`` to clear.
    color : PaletteColor or None
        The new colour, or ``null`` to clear.
    start_date : date or None
        New first day, or ``null`` to clear.
    end_date : date or None
        New last day, or ``null`` to clear.
    """

    name: str
    emoji: EmojiField = None
    color: PaletteColor | None = None
    start_date: date | None = None
    end_date: date | None = None


class AssignTransactionRequest(BaseModel):
    """Body for assigning a transaction to an event.

    Attributes
    ----------
    transaction_id : UUID
        The transaction to group under the event. Must be the caller's and not
        already a member of a different event.
    """

    transaction_id: UUID


class EventResponse(BaseModel):
    """One event as returned to the client, with its derived total.

    Attributes
    ----------
    id : UUID
        Stable identifier of the event.
    name : str
        Human-readable name for the occasion.
    emoji : str or None
        The event's emoji, or ``null`` if unset (ADR 0027).
    color : PaletteColor or None
        The event's colour, or ``null`` if unset.
    start_date : date or None
        Optional first day of the occasion.
    end_date : date or None
        Optional last day of the occasion.
    status : EventStatus
        Lifecycle state (``active`` or ``closed``); purely organizational.
    member_count : int
        How many transactions are grouped under the event.
    total : int
        The net cost of the event in minor units (cents): the sum of its members'
        ``effective_amount`` (transfers count zero, advances only the user's
        share, reimbursements zero). ``0`` for an empty event.
    currency : str or None
        ISO 4217 code of ``total`` — the members' shared currency. ``null`` for an
        empty event, which has no currency of its own.
    created_at : datetime
        When the event was created (timezone-aware, UTC).
    """

    id: UUID
    name: str
    emoji: str | None
    color: PaletteColor | None
    start_date: date | None
    end_date: date | None
    status: EventStatus
    member_count: int
    total: int
    currency: str | None
    created_at: datetime

    @classmethod
    def from_domain(
        cls, event: Event, *, total: Money | None, member_count: int
    ) -> "EventResponse":
        """Project a domain :class:`~traccio.domain.models.Event` with its total.

        Parameters
        ----------
        event : Event
            The domain event to project.
        total : Money or None
            The event's net total (see :func:`~traccio.domain.events.event_total`),
            or ``None`` for an empty event.
        member_count : int
            How many transactions are grouped under the event.

        Returns
        -------
        EventResponse
            The client-facing view of ``event``.
        """
        return cls(
            id=event.id,
            name=event.name,
            emoji=event.emoji,
            color=event.color,
            start_date=event.start_date,
            end_date=event.end_date,
            status=event.status,
            member_count=member_count,
            total=0 if total is None else total.amount,
            currency=None if total is None else total.currency,
            created_at=event.created_at,
        )


class EventSummaryResponse(BaseModel):
    """An event's spending, broken down by category (ADR 0028).

    Reuses the dashboard's own aggregation: the members are a sequence of
    transactions, so :func:`~traccio.domain.dashboard.summarize` produces the
    same two-level ``by_category`` (ADR 0018) it does for a period. An event
    is single-currency by construction (``assign_transaction`` refuses a
    mixed-currency member), so there is exactly one figure per field;
    ``currency`` is ``null`` and the totals are ``0`` for an empty event.

    Attributes
    ----------
    spending : int
        Total spending across the members, a positive magnitude (cents) — the
        sum of every negative ``effective_amount``.
    income : int
        Total income across the members, a positive magnitude.
    net : int
        ``income - spending``, signed. Matches ``EventResponse.total``.
    currency : str or None
        ISO 4217 code of the figures, or ``null`` for an empty event.
    by_category : list[CategoryGroupSummaryResponse]
        The members' spending/income partitioned by category root, each with
        its children rolled up — the same shape the dashboard returns, so the
        client reuses its donut and breakdown list unchanged.
    """

    spending: int
    income: int
    net: int
    currency: str | None
    by_category: list[CategoryGroupSummaryResponse]

    @classmethod
    def from_currency_summary(
        cls,
        summary: CurrencySummary | None,
        *,
        display: "dict[UUID, CategoryDisplay]",
    ) -> "EventSummaryResponse":
        """Project the single :class:`~traccio.domain.dashboard.CurrencySummary`.

        Parameters
        ----------
        summary : CurrencySummary or None
            The one currency summary ``summarize`` produced for the members,
            or ``None`` when the event has no members.
        display : dict[UUID, CategoryDisplay]
            Category id → name/colour/icon, for resolving each ``by_category``
            row's display fields (same map the dashboard builds).

        Returns
        -------
        EventSummaryResponse
            The client-facing breakdown.
        """
        if summary is None:
            return cls(spending=0, income=0, net=0, currency=None, by_category=[])
        return cls(
            spending=summary.spending.amount,
            income=summary.income.amount,
            net=summary.net.amount,
            currency=summary.currency,
            by_category=[
                CategoryGroupSummaryResponse.from_domain(group, display=display)
                for group in summary.by_category
            ],
        )


class EventsResponse(BaseModel):
    """Envelope for the events list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    events : list[EventResponse]
        The user's events, oldest first.
    """

    events: list[EventResponse]
