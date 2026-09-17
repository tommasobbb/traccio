"""Pure currency conversion for the opt-in dashboard combined total (ADR 0021).

The per-currency breakdown (``domain/dashboard.py::summarize``) is unchanged
and remains the source of truth. This module rewrites a period's transactions
into a single base currency **before** ``effective_amount`` and ``summarize``
run, so a second ``summarize`` pass yields one combined ``CurrencySummary``
with every partition (category / bucket / account / comparison) converted for
free — no parallel aggregation to keep in sync.

Conversion is historical: each movement uses the rate for its own effective
date (``booked_at`` else ``value_date``); a dateless movement uses the latest
rate. Rounding is half-up to integer cents. If any needed rate is missing the
whole converted view is withheld (:class:`MissingRate`) rather than returning
a partial total — best-effort, never wrong.

This module imports nothing outside ``domain/`` and does no I/O: the caller
supplies a ``rate_for`` resolver.
"""

from collections.abc import Callable, Mapping, Sequence
from datetime import date, datetime
from decimal import ROUND_HALF_UP, Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from traccio.domain.models import Transaction
from traccio.domain.money import CurrencyCode, Money
from traccio.domain.transaction_time import effective_calendar_date

# A resolver from (currency, effective date or None) to the quote->base rate,
# or ``None`` when no rate is available for that pair. ``date is None`` asks
# for the latest available rate (a dateless movement).
RateResolver = Callable[[CurrencyCode, date | None], Decimal | None]


class FxRate(BaseModel):
    """One ECB reference rate: ``1 quote`` = ``rate`` ``base`` on ``rate_date``.

    The value object crossing the ``db``/``services``/``domain`` boundary for
    a cached rate. ``rate`` is an exact :class:`~decimal.Decimal` — never a
    float (root ``CLAUDE.md``: money is never floating point).

    Attributes
    ----------
    base : str
        ISO 4217 code the rate converts *into*.
    quote : str
        ISO 4217 code the rate converts *from*.
    rate_date : date
        The ECB publication date this rate is for.
    rate : Decimal
        Multiply an amount in ``quote`` by this to get ``base``.
    fetched_at : datetime
        When this row was retrieved from the rate API (timezone-aware, UTC).
        Only the most recent ``rate_date`` is ever re-fetched.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    base: CurrencyCode
    quote: CurrencyCode
    rate_date: date
    rate: Decimal
    fetched_at: datetime


class MissingRate(BaseModel):
    """Returned by :func:`to_base_currency` when a required rate is absent.

    Carries only the offending currency code — a value-free identifier, never
    an amount (``.claude/rules/data-safety.md``).

    Attributes
    ----------
    currency : str
        The currency for which no rate could be resolved.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    currency: CurrencyCode


class ConvertedInput(BaseModel):
    """A period's transactions and advance shares, all rewritten into one base.

    Feed straight into ``domain/dashboard.py::summarize`` for a combined
    summary in :attr:`base`.

    Attributes
    ----------
    base : str
        The currency every ``money`` below is now expressed in.
    transactions : tuple[Transaction, ...]
        The input transactions with ``money`` converted; order preserved.
    advance_shares : dict[UUID, Money]
        The input advance shares with each ``Money`` converted.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    base: CurrencyCode
    transactions: tuple[Transaction, ...]
    advance_shares: dict[UUID, Money]


def convert_amount(money: Money, *, to: CurrencyCode, rate: Decimal) -> Money:
    """Convert ``money`` into ``to`` at ``rate`` (quote->base), half-up to cents.

    A no-op (``rate`` ignored) when ``money`` is already in ``to``.

    Parameters
    ----------
    money : Money
        The amount to convert. Its sign is preserved.
    to : str
        The target ISO 4217 code.
    rate : Decimal
        Multiplier: an amount in ``money.currency`` times this yields ``to``.

    Returns
    -------
    Money
        The converted amount, in ``to``, in integer minor units.
    """
    if money.currency == to:
        return money
    converted = (Decimal(money.amount) * rate).quantize(Decimal(1), rounding=ROUND_HALF_UP)
    return Money(amount=int(converted), currency=to)


def _effective_date(transaction: Transaction) -> date | None:
    """The calendar date a transaction converts at — see ``domain/transaction_time.py``."""
    return effective_calendar_date(transaction)


def to_base_currency(
    transactions: Sequence[Transaction],
    advance_shares: Mapping[UUID, Money],
    *,
    base: CurrencyCode,
    rate_for: RateResolver,
) -> ConvertedInput | MissingRate:
    """Rewrite a period's transactions and advance shares into ``base``.

    Each transaction's ``money`` is converted at the rate for its own
    effective date (:func:`_effective_date`); a dateless transaction uses the
    latest rate (``rate_for(currency, None)``). Each advance share is
    converted at the date of the transaction it belongs to. A transaction (or
    share) already in ``base`` passes through untouched.

    The first currency for which ``rate_for`` returns ``None`` aborts the
    whole conversion — a partial combined total would be misleading.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The period's transactions (already filtered by the caller).
    advance_shares : Mapping[UUID, Money]
        Signed advance spending shares keyed by transaction id, as
        ``summarize`` consumes them.
    base : str
        Target ISO 4217 code (``Settings.fx_base_currency``).
    rate_for : RateResolver
        Resolver supplied by ``services/fx.py``.

    Returns
    -------
    ConvertedInput or MissingRate
        The rewritten inputs, or the first currency that had no rate.
    """
    converted_txns: list[Transaction] = []
    converted_shares: dict[UUID, Money] = {}

    for transaction in transactions:
        on = _effective_date(transaction)
        currency = transaction.money.currency
        if currency != base:
            rate = rate_for(currency, on)
            if rate is None:
                return MissingRate(currency=currency)
            transaction = transaction.model_copy(
                update={"money": convert_amount(transaction.money, to=base, rate=rate)}
            )
        converted_txns.append(transaction)

        share = advance_shares.get(transaction.id)
        if share is not None:
            if share.currency == base:
                converted_shares[transaction.id] = share
            else:
                rate = rate_for(share.currency, on)
                if rate is None:
                    return MissingRate(currency=share.currency)
                converted_shares[transaction.id] = convert_amount(share, to=base, rate=rate)

    return ConvertedInput(
        base=base,
        transactions=tuple(converted_txns),
        advance_shares=converted_shares,
    )
