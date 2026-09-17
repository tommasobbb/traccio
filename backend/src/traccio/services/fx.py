"""FX rate orchestration for the opt-in dashboard combined total (ADR 0021).

Bridges the cached ``fx_rates`` table (``db/repositories.py``) and the
frankfurter.dev client (``providers/frankfurter.py``) to hand
``domain/fx.py::to_base_currency`` a pure ``rate_for`` resolver. Fetches only
what the period actually needs — one range call per foreign currency — and
persists every fetched rate so a later render, or a brief API outage, is
served from cache.

Best-effort: if the API fails and the cache cannot cover a currency the
period needs, returns :class:`FxUnavailable` and the caller withholds the
converted view entirely rather than showing a partial total.

Imports ``domain``, ``db``, ``providers``, ``core`` — a normal ``services``
module.
"""

from collections.abc import Sequence
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal

from pydantic import BaseModel, ConfigDict
from sqlalchemy.orm import Session

from traccio.core.logging import get_logger
from traccio.db.repositories import get_fx_rates, latest_fx_rate_fetched_at, upsert_fx_rates
from traccio.domain.fx import FxRate, RateResolver
from traccio.domain.models import Transaction
from traccio.domain.transaction_time import effective_calendar_date
from traccio.providers.frankfurter import FrankfurterClient, FxRateError

logger = get_logger(__name__)

# Fetch the range starting a week before the earliest movement so a movement
# on a weekend/holiday always has an ECB publication day at or before it.
_RANGE_BACKFILL_DAYS = 7


class FxUnavailable(BaseModel):
    """Rates for at least one needed currency could not be obtained.

    Attributes
    ----------
    reason : str
        A stable, value-free code — currently only ``"rates_unavailable"``.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    reason: str = "rates_unavailable"


def _needed(
    transactions: Sequence[Transaction], *, base: str
) -> tuple[set[str], date | None, date | None, bool]:
    """The non-base currencies, the movement-date span, and whether any is dateless."""
    currencies: set[str] = set()
    dates: list[date] = []
    has_dateless = False
    for transaction in transactions:
        if transaction.money.currency == base:
            continue
        currencies.add(transaction.money.currency)
        on = effective_calendar_date(transaction)
        if on is None:
            has_dateless = True
        else:
            dates.append(on)
    if not dates:
        return currencies, None, None, has_dateless
    return currencies, min(dates), max(dates), has_dateless


def _index(rates: Sequence[FxRate]) -> dict[str, list[tuple[date, Decimal]]]:
    """Group cached rates by quote currency, each list ascending by date."""
    out: dict[str, list[tuple[date, Decimal]]] = {}
    for fx in rates:
        out.setdefault(fx.quote, []).append((fx.rate_date, fx.rate))
    for series in out.values():
        series.sort()
    return out


def build_rate_resolver(
    session: Session,
    client: FrankfurterClient,
    *,
    base: str,
    transactions: Sequence[Transaction],
    now: datetime,
    ttl_hours: int,
) -> RateResolver | FxUnavailable:
    """Return a ``rate_for`` resolver covering every currency ``transactions`` needs.

    Fetches from frankfurter only what the cache is missing, persists it, then
    builds an in-memory index. On an API error the cache is used as-is; if
    that leaves a needed currency with no rate at all, returns
    :class:`FxUnavailable`.

    Parameters
    ----------
    session : Session
        Active database session. Not committed here — like every function in
        ``db/repositories.py``, the caller owns the transaction boundary; a
        newly fetched rate is only persisted once the caller commits.
    client : FrankfurterClient
        The rate API client (its lifetime is the caller's).
    base : str
        Target currency (``Settings.fx_base_currency``).
    transactions : Sequence[Transaction]
        The period's transactions.
    now : datetime
        Current instant, injected — used for the range's upper bound and the
        TTL check, never read from the clock here.
    ttl_hours : int
        How stale the newest cached row may be before the latest rate is
        re-fetched (``Settings.fx_rate_ttl_hours``).

    Returns
    -------
    RateResolver or FxUnavailable
        A ``(currency, date | None) -> Decimal | None`` resolver, or the
        signal that conversion cannot proceed.
    """
    quotes, min_date, max_date, has_dateless = _needed(transactions, base=base)
    if not quotes:
        # Everything is already in base; a trivial resolver still lets the
        # caller run one clean summarize pass.
        return lambda currency, _on: Decimal(1) if currency == base else None

    today = now.astimezone(UTC).date()
    range_end = max(max_date, today) if max_date is not None else today
    range_start = (
        (min_date - timedelta(days=_RANGE_BACKFILL_DAYS)) if min_date is not None else today
    )
    ttl = timedelta(hours=ttl_hours)

    had_error = False
    for quote in sorted(quotes):
        cached = get_fx_rates(session, base=base, quotes=[quote], up_to=range_end)
        cached_dates = [fx.rate_date for fx in cached]
        covers_span = bool(cached_dates) and min(cached_dates) <= range_start
        newest_stale = not cached_dates or max(cached_dates) < range_end - timedelta(
            days=_RANGE_BACKFILL_DAYS
        )
        latest_at = latest_fx_rate_fetched_at(session, base=base, quote=quote)
        latest_needs_refresh = has_dateless and (latest_at is None or now - latest_at > ttl)

        if covers_span and not newest_stale and not latest_needs_refresh:
            continue

        try:
            # frankfurter's ``base``/``symbols`` are "1 base = N symbol"; we
            # want "1 quote = rate base", so ask with base=quote, symbols=[base]
            # and read the base out of each day's rates.
            fetched: list[FxRate] = []
            if min_date is not None and (not covers_span or newest_stale):
                for day, day_rates in client.rates_in_range(
                    base=quote, symbols=[base], start=range_start, end=range_end
                ).items():
                    rate = day_rates.get(base)
                    if rate is not None:
                        fetched.append(
                            FxRate(base=base, quote=quote, rate_date=day, rate=rate, fetched_at=now)
                        )
            if latest_needs_refresh:
                day, day_rates = client.latest_rates(base=quote, symbols=[base])
                rate = day_rates.get(base)
                if rate is not None:
                    fetched.append(
                        FxRate(base=base, quote=quote, rate_date=day, rate=rate, fetched_at=now)
                    )
            if fetched:
                upsert_fx_rates(session, rates=fetched)
        except FxRateError:
            had_error = True
            logger.warning("fx.fetch_failed", quote=quote)

    all_cached = get_fx_rates(session, base=base, quotes=sorted(quotes), up_to=range_end)
    index = _index(all_cached)

    if had_error and any(quote not in index for quote in quotes):
        return FxUnavailable()

    def rate_for(currency: str, on: date | None) -> Decimal | None:
        if currency == base:
            return Decimal(1)
        series = index.get(currency)
        if not series:
            return None
        if on is None:
            return series[-1][1]
        eligible = [rate for rate_date, rate in series if rate_date <= on]
        return eligible[-1] if eligible else None

    return rate_for
