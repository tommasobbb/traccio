"""Tests for the pure FX conversion domain module (``domain/fx.py``, ADR 0021).

No database, no network — the caller supplies a ``rate_for`` resolver.
Fixtures are synthetic: round rates, ``"TEST MERCHANT 01"``.
"""

from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

from traccio.domain.enums import KeyStrategy, TransactionRole, TransactionStatus
from traccio.domain.fx import (
    ConvertedInput,
    MissingRate,
    convert_amount,
    to_base_currency,
)
from traccio.domain.models import Transaction
from traccio.domain.money import Money


def _tx(
    *,
    amount: int,
    currency: str,
    when: datetime | None,
    role: TransactionRole = TransactionRole.PERSONAL,
) -> Transaction:
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=amount, currency=currency),
        booked_at=when,
        value_date=None,
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        role=role,
        stable_key=str(uuid4()),
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


# --- convert_amount ----------------------------------------------------------


def test_convert_amount_rounds_half_up() -> None:
    # 1005 * 0.5 = 502.5 -> 503 (half up), not 502.
    assert convert_amount(
        Money(amount=1005, currency="USD"), to="EUR", rate=Decimal("0.5")
    ) == Money(amount=503, currency="EUR")


def test_convert_amount_preserves_sign() -> None:
    assert convert_amount(
        Money(amount=-10000, currency="USD"), to="EUR", rate=Decimal("0.9")
    ) == Money(amount=-9000, currency="EUR")


def test_convert_amount_zero_stays_zero() -> None:
    assert convert_amount(Money(amount=0, currency="USD"), to="EUR", rate=Decimal("1.23")) == Money(
        amount=0, currency="EUR"
    )


def test_convert_amount_is_a_noop_for_the_base_currency() -> None:
    original = Money(amount=1234, currency="EUR")
    assert convert_amount(original, to="EUR", rate=Decimal("99")) is original


# --- to_base_currency ------------------------------------------------------


_D1 = datetime(2026, 3, 2, tzinfo=UTC)
_D2 = datetime(2026, 3, 10, tzinfo=UTC)


def _rate_for(table: dict[tuple[str, str | None], Decimal]):
    def resolver(currency: str, on: object) -> Decimal | None:
        key = (currency, on.isoformat() if on is not None else None)  # type: ignore[union-attr]
        if key in table:
            return table[key]
        # Fall back to a "latest" entry if present.
        return table.get((currency, None))

    return resolver


def test_to_base_currency_converts_each_row_at_its_own_date() -> None:
    usd_early = _tx(amount=-10000, currency="USD", when=_D1)
    usd_late = _tx(amount=-10000, currency="USD", when=_D2)
    eur_native = _tx(amount=-500, currency="EUR", when=_D1)
    resolver = _rate_for(
        {
            ("USD", "2026-03-02"): Decimal("0.90"),
            ("USD", "2026-03-10"): Decimal("0.80"),
        }
    )

    result = to_base_currency([usd_early, usd_late, eur_native], {}, base="EUR", rate_for=resolver)

    assert isinstance(result, ConvertedInput)
    assert [t.money.amount for t in result.transactions] == [-9000, -8000, -500]
    assert all(t.money.currency == "EUR" for t in result.transactions)


def test_to_base_currency_uses_latest_rate_for_a_dateless_row() -> None:
    dateless = _tx(amount=-10000, currency="USD", when=None)
    resolver = _rate_for({("USD", None): Decimal("0.75")})

    result = to_base_currency([dateless], {}, base="EUR", rate_for=resolver)

    assert isinstance(result, ConvertedInput)
    assert result.transactions[0].money == Money(amount=-7500, currency="EUR")


def test_to_base_currency_returns_missing_rate_for_an_unresolvable_currency() -> None:
    chf = _tx(amount=-10000, currency="CHF", when=_D1)
    resolver = _rate_for({("USD", "2026-03-02"): Decimal("0.9")})

    result = to_base_currency([chf], {}, base="EUR", rate_for=resolver)

    assert result == MissingRate(currency="CHF")


def test_to_base_currency_converts_the_advance_share_too() -> None:
    advance = _tx(amount=-20000, currency="USD", when=_D1, role=TransactionRole.ADVANCE)
    shares = {advance.id: Money(amount=-8000, currency="USD")}
    resolver = _rate_for({("USD", "2026-03-02"): Decimal("0.5")})

    result = to_base_currency([advance], shares, base="EUR", rate_for=resolver)

    assert isinstance(result, ConvertedInput)
    assert result.advance_shares[advance.id] == Money(amount=-4000, currency="EUR")
