"""Persisted :class:`~traccio.domain.models.User`."""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import Boolean, Date, DateTime, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base


class UserRow(Base):
    """Persisted :class:`~traccio.domain.models.User`.

    Attributes
    ----------
    id : UUID
        Primary key.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    tracking_start_date : date or None
        The first day the user wants counted (ADR 0024). ``None`` — the
        default and the state before this column existed — means "no floor,
        show everything". A calendar date, not a datetime: the floor is a
        whole-day boundary and the user picks a month, not an instant.
    meal_vouchers_enabled : bool
        Whether the meal-vouchers dashboard breakout is on (ADR 0029).
        Defaults ``False`` — most users have no meal-voucher benefit, and
        the feature is opt-in per user rather than detected. Two scalar
        settings still do not earn a dedicated ``user_settings`` table
        (ADR 0024's reasoning): both fit comfortably as columns here, and a
        table is worth it once a *third* setting, or one with real
        structure, shows up.
    """

    __tablename__ = "users"

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    tracking_start_date: Mapped[date | None] = mapped_column(Date(), nullable=True)
    meal_vouchers_enabled: Mapped[bool] = mapped_column(Boolean(), nullable=False, default=False)
