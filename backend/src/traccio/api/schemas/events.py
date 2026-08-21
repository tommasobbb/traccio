"""Request and response schemas for the event endpoints.

An event groups transactions from one occasion so the user can see what it
actually cost. Its ``total`` is **derived** from the members' ``effective_amount``
by the one pure :func:`~traccio.domain.events.event_total` function, never stored
— the client renders it and never recomputes. An event has no currency of its
own: ``currency`` is the members' shared currency, ``null`` for an empty event
(whose ``total`` is ``0``).

Scope (2026-08-21): the total is a single net figure; a per-category breakdown
is a later slice, gated on categorization existing (see ``tasks/backlog.md``).
"""

from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.enums import EventStatus
from traccio.domain.models import Event
from traccio.domain.money import Money


class CreateEventRequest(BaseModel):
    """Body for creating an event.

    Attributes
    ----------
    name : str
        Human-readable name for the occasion (e.g. ``"Turkey 2026"``).
    start_date : date or None
        Optional first day of the occasion; a hint, not a membership rule.
    end_date : date or None
        Optional last day of the occasion.
    """

    name: str
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
            start_date=event.start_date,
            end_date=event.end_date,
            status=event.status,
            member_count=member_count,
            total=0 if total is None else total.amount,
            currency=None if total is None else total.currency,
            created_at=event.created_at,
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
