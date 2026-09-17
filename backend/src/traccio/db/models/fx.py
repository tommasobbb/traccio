"""Persisted ECB reference rate cache (ADR 0021)."""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import Date, DateTime, String, Text, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base


class FxRateRow(Base):
    """A cached ECB reference rate (ADR 0021).

    ``1 quote`` = ``rate`` ``base`` on ``rate_date``. **This is the one table
    not scoped by ``user_id``**: ECB rates are public and identical for every
    user, the same category as the seeded ``Category`` templates
    (``docs/domain.md``'s stated exception). Historical rows are immutable
    once fetched; only the row for the most recent ``rate_date`` is ever
    re-fetched, when its ``fetched_at`` is older than
    ``Settings.fx_rate_ttl_hours``.

    Attributes
    ----------
    id : UUID
        Primary key.
    base : str
        ISO 4217 code the rate converts *into*.
    quote : str
        ISO 4217 code the rate converts *from*.
    rate_date : date
        The ECB publication date this rate is for.
    rate : str
        The multiplier as an **exact decimal string** (e.g. ``"1.0834"``) —
        never a float and never ``Numeric``, consistent with "money is
        integer cents, never floating point". Parsed to
        :class:`~decimal.Decimal` in the repository.
    fetched_at : datetime
        When this row was retrieved from the rate API (timezone-aware, UTC).
    """

    __tablename__ = "fx_rates"
    # Named explicitly: NAMING_CONVENTION's "uq" pattern keys off the first
    # column only (column_0_name), which for a 3-column constraint would
    # generate "uq_fx_rates_base" — different from the name migration
    # f6a7b8c9d0e1 already gave this constraint in every deployed database.
    # A migration's applied DDL is never edited after the fact, so the model
    # names it explicitly to match instead.
    __table_args__ = (
        UniqueConstraint("base", "quote", "rate_date", name="uq_fx_rates_base_quote_rate_date"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    base: Mapped[str] = mapped_column(String(3))
    quote: Mapped[str] = mapped_column(String(3))
    rate_date: Mapped[date] = mapped_column(Date)
    rate: Mapped[str] = mapped_column(Text)
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
