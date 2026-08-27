"""Tests for the FX rate orchestrator (``services/fx.py``, ADR 0021).

An in-memory SQLite engine backs the ``fx_rates`` cache; a
:class:`httpx.MockTransport` stands in for frankfurter.dev so nothing hits
the network. Values are synthetic (round rates, invented currencies).
"""

from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import uuid4

import httpx
from sqlalchemy import Engine, create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.db.base import Base
from traccio.db.models import FxRateRow
from traccio.domain.enums import KeyStrategy, TransactionStatus
from traccio.domain.models import Transaction
from traccio.domain.money import Money
from traccio.providers.frankfurter import FrankfurterClient
from traccio.services.fx import FxUnavailable, build_rate_resolver

_NOW = datetime(2026, 3, 13, 12, 0, tzinfo=UTC)


def _engine() -> Engine:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    return engine


def _tx(*, amount: int, currency: str, when: datetime | None) -> Transaction:
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=amount, currency=currency),
        booked_at=when,
        value_date=None,
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        stable_key=str(uuid4()),
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def _frankfurter(handler: httpx.MockTransport) -> FrankfurterClient:
    return FrankfurterClient(base_url="https://fx.example.test", transport=handler)


# Synthetic USD->EUR rates: 1 USD = 0.92 EUR on the 2nd, 0.90 on the 10th.
_RANGE_BODY = {
    "amount": 1,
    "base": "USD",
    "start_date": "2026-03-02",
    "end_date": "2026-03-10",
    "rates": {"2026-03-02": {"EUR": 0.92}, "2026-03-10": {"EUR": 0.90}},
}
_LATEST_BODY = {"amount": 1, "base": "USD", "date": "2026-03-13", "rates": {"EUR": 0.88}}


def _ok_handler() -> httpx.MockTransport:
    def handle(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/latest"):
            return httpx.Response(200, json=_LATEST_BODY)
        return httpx.Response(200, json=_RANGE_BODY)

    return httpx.MockTransport(handle)


def _down_handler() -> httpx.MockTransport:
    def handle(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, text="upstream down")

    return httpx.MockTransport(handle)


def test_cold_cache_fetches_the_range_persists_it_and_resolves_by_date() -> None:
    engine = _engine()
    client = _frankfurter(_ok_handler())
    txns = [
        _tx(amount=-10000, currency="USD", when=datetime(2026, 3, 3, tzinfo=UTC)),
        _tx(amount=-10000, currency="USD", when=datetime(2026, 3, 12, tzinfo=UTC)),
    ]
    with Session(engine) as session:
        resolver = build_rate_resolver(
            session, client, base="EUR", transactions=txns, now=_NOW, ttl_hours=12
        )
        assert not isinstance(resolver, FxUnavailable)
        # A movement on the 3rd uses the 2nd's rate; one on the 12th uses the 10th's.
        assert resolver("USD", date(2026, 3, 3)) == Decimal("0.92")
        assert resolver("USD", date(2026, 3, 12)) == Decimal("0.90")
        assert resolver("EUR", date(2026, 3, 3)) == Decimal(1)
        rows = session.scalars(select(FxRateRow)).all()
        assert {(r.quote, r.base, Decimal(r.rate)) for r in rows} == {
            ("USD", "EUR", Decimal("0.92")),
            ("USD", "EUR", Decimal("0.90")),
        }


def test_warm_cache_is_used_when_the_api_is_down() -> None:
    engine = _engine()
    with Session(engine) as session:
        session.add(
            FxRateRow(
                id=uuid4(),
                base="EUR",
                quote="USD",
                rate_date=date(2026, 2, 20),
                rate="0.95",
                fetched_at=_NOW,
            )
        )
        session.commit()

    client = _frankfurter(_down_handler())
    txns = [_tx(amount=-10000, currency="USD", when=datetime(2026, 3, 3, tzinfo=UTC))]
    with Session(engine) as session:
        resolver = build_rate_resolver(
            session, client, base="EUR", transactions=txns, now=_NOW, ttl_hours=12
        )
        assert not isinstance(resolver, FxUnavailable)
        # The cache has a rate on or before the movement date, even if stale.
        assert resolver("USD", date(2026, 3, 3)) == Decimal("0.95")


def test_api_down_and_no_cache_is_fx_unavailable() -> None:
    engine = _engine()
    client = _frankfurter(_down_handler())
    txns = [_tx(amount=-10000, currency="USD", when=datetime(2026, 3, 3, tzinfo=UTC))]
    with Session(engine) as session:
        result = build_rate_resolver(
            session, client, base="EUR", transactions=txns, now=_NOW, ttl_hours=12
        )
        assert result == FxUnavailable(reason="rates_unavailable")


def test_dateless_movement_fetches_and_resolves_the_latest_rate() -> None:
    engine = _engine()
    client = _frankfurter(_ok_handler())
    txns = [_tx(amount=-10000, currency="USD", when=None)]
    with Session(engine) as session:
        resolver = build_rate_resolver(
            session, client, base="EUR", transactions=txns, now=_NOW, ttl_hours=12
        )
        assert not isinstance(resolver, FxUnavailable)
        assert resolver("USD", None) == Decimal("0.88")


def test_no_foreign_currency_returns_a_trivial_resolver_without_fetching() -> None:
    engine = _engine()

    # A handler that would fail the test if called at all.
    def handle(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("should not fetch when everything is already in base")

    client = _frankfurter(httpx.MockTransport(handle))
    txns = [_tx(amount=-500, currency="EUR", when=datetime(2026, 3, 3, tzinfo=UTC))]
    with Session(engine) as session:
        resolver = build_rate_resolver(
            session, client, base="EUR", transactions=txns, now=_NOW, ttl_hours=12
        )
        assert not isinstance(resolver, FxUnavailable)
        assert resolver("EUR", date(2026, 3, 3)) == Decimal(1)
