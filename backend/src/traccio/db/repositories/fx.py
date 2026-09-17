"""FX-rate cache queries (ADR 0021).

The one group of queries not scoped by ``user_id``: ECB reference rates are
public and identical for every user (``docs/domain.md``'s stated exception,
same as seeded ``Category`` templates)."""

from collections.abc import Sequence
from datetime import date, datetime
from decimal import Decimal
from typing import TYPE_CHECKING
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.models import (
    FxRateRow,
)
from traccio.domain.fx import FxRate
from traccio.domain.utc import as_aware_utc


def _row_to_fx_rate(row: FxRateRow) -> FxRate:
    """Translate an :class:`FxRateRow` into a domain :class:`FxRate`.

    Parses the exact-decimal-string ``rate`` column into :class:`Decimal`, and
    treats a naive ``fetched_at`` (SQLite drops tzinfo) as UTC.
    """
    return FxRate(
        base=row.base,
        quote=row.quote,
        rate_date=row.rate_date,
        rate=Decimal(row.rate),
        fetched_at=as_aware_utc(row.fetched_at),
    )


def get_fx_rates(
    session: Session, *, base: str, quotes: Sequence[str], up_to: date
) -> list[FxRate]:
    """Return every cached rate for ``base`` from any of ``quotes``, dated ``<= up_to``.

    Ordered by ``(quote, rate_date)`` so a caller can walk each currency's
    history and pick "the rate on or before date D".

    Parameters
    ----------
    session : Session
        Active database session.
    base : str
        The currency rates convert into.
    quotes : Sequence[str]
        The currencies to include (rates convert *from* these).
    up_to : date
        Inclusive upper bound on ``rate_date``.

    Returns
    -------
    list[FxRate]
        Cached rates, ``(quote, rate_date)`` ascending. Empty if none.
    """
    if not quotes:
        return []
    rows = session.scalars(
        select(FxRateRow)
        .where(
            FxRateRow.base == base,
            FxRateRow.quote.in_(list(quotes)),
            FxRateRow.rate_date <= up_to,
        )
        .order_by(FxRateRow.quote, FxRateRow.rate_date)
    ).all()
    return [_row_to_fx_rate(row) for row in rows]


def latest_fx_rate_fetched_at(session: Session, *, base: str, quote: str) -> datetime | None:
    """Return ``fetched_at`` of the most recent cached ``rate_date`` for a pair.

    Used to decide whether the current-day row is stale enough to re-fetch
    (``Settings.fx_rate_ttl_hours``). ``None`` when the pair is not cached at
    all.
    """
    row = session.scalars(
        select(FxRateRow)
        .where(FxRateRow.base == base, FxRateRow.quote == quote)
        .order_by(FxRateRow.rate_date.desc())
        .limit(1)
    ).one_or_none()
    if row is None:
        return None
    return as_aware_utc(row.fetched_at)


def upsert_fx_rates(session: Session, *, rates: Sequence[FxRate]) -> None:
    """Insert new cached rates, refreshing ``rate``/``fetched_at`` on a re-fetch.

    Idempotent on ``(base, quote, rate_date)`` via read-then-write (no
    dialect-specific upsert), matching :func:`upsert_account`. Historical rows
    are normally written once; the most recent ``rate_date`` may be re-fetched
    (its published value can still change until it is final), so an existing
    row's ``rate`` and ``fetched_at`` are updated. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    rates : Sequence[FxRate]
        The rates to persist. ``rate`` is stored as its exact decimal string.
    """
    for fx in rates:
        existing = session.scalars(
            select(FxRateRow).where(
                FxRateRow.base == fx.base,
                FxRateRow.quote == fx.quote,
                FxRateRow.rate_date == fx.rate_date,
            )
        ).one_or_none()
        if existing is None:
            session.add(
                FxRateRow(
                    id=uuid4(),
                    base=fx.base,
                    quote=fx.quote,
                    rate_date=fx.rate_date,
                    rate=str(fx.rate),
                    fetched_at=fx.fetched_at,
                )
            )
        else:
            existing.rate = str(fx.rate)
            existing.fetched_at = fx.fetched_at
