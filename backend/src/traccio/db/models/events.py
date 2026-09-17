"""Persisted :class:`~traccio.domain.models.Event`."""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import Date, DateTime, ForeignKey, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column, _token_column
from traccio.domain.enums import EventStatus, PaletteColor


class EventRow(Base):
    """Persisted :class:`~traccio.domain.models.Event`.

    A user-defined grouping of transactions from one occasion. Membership lives
    on ``transactions.event_id`` (a transaction has at most one event), not in a
    join table. Deleting an event clears its members' ``event_id`` first (done in
    the repository, not a DB cascade, to stay portable) — the transactions
    survive. Nothing about the total is stored here; it is derived from the
    members (see :func:`~traccio.domain.events.event_total`).

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    name : str
        Human-readable name for the occasion.
    emoji : str or None
        Optional single emoji for the event's tile (validated at the API
        edge, ADR 0027). ``VARCHAR(16)`` — comfortably wide for a joined
        emoji sequence, never a caption.
    color : PaletteColor or None
        Optional colour token for the tile, shared vocabulary (ADR 0017).
    start_date : date or None
        Optional first day of the occasion (a hint, not a membership rule).
    end_date : date or None
        Optional last day of the occasion.
    status : EventStatus
        Lifecycle state; ``active`` when created.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "events"

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    emoji: Mapped[str | None] = mapped_column(String(16), nullable=True)
    color: Mapped[PaletteColor | None] = mapped_column(_token_column(PaletteColor), nullable=True)
    start_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    end_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    status: Mapped[EventStatus] = mapped_column(_enum_column(EventStatus))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
