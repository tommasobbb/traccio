"""The dashboard summary: real spending and income, per currency and category.

M2's "done when" (``tasks/ROADMAP.md``): "I can tag a real advance from a real
trip and watch the dashboard show my actual share rather than the full
amount." This is the single place that answers "how much did I actually spend
and receive" from :func:`~traccio.domain.effective_amount.effective_amount`
alone — never raw ``amount`` (see ``docs/architecture.md``'s invariant that the
two are never mixed) — so a transfer between the user's own accounts does not
inflate spending, an advance counts only the user's declared share, and a
reimbursement is not income.

Each currency's totals additionally partition by
:func:`~traccio.domain.categories.effective_category` (ADR 0007's "Revisit
when" — the category breakdown mockup card, previously blocked, unblocked
here) and by calendar day (the 2026-08-25 revision — the "Andamento netto"
mockup card, granularity settled as daily): neither a category nor a day
spans currencies, so both partitions live inside :class:`CurrencySummary`,
never beside it.

This module imports nothing outside ``domain/``.
"""

from collections.abc import Mapping, Sequence
from datetime import UTC, date
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from traccio.domain.categories import effective_category
from traccio.domain.effective_amount import effective_amount
from traccio.domain.models import Transaction
from traccio.domain.money import CurrencyCode, Money


def _day_of(transaction: Transaction) -> date | None:
    """The UTC calendar day a transaction is bucketed under, or ``None``.

    Same "when" as :func:`~traccio.db.repositories.list_transactions_in_period`
    uses to filter — ``coalesce(booked_at, value_date)`` — so a row can never
    be counted in the period but excluded from every day bucket, or vice
    versa. Every timestamp in this system is UTC (root ``CLAUDE.md``), but a
    value round-tripped through SQLite comes back naive; a naive value is
    treated as UTC rather than the local zone, per the same guard
    :func:`traccio.domain.sync_schedule._as_aware_utc` uses. ``None`` when
    both dates are unset — there is nothing to bucket, unlike the currency and
    category partitions which always have a value.
    """
    when = transaction.booked_at or transaction.value_date
    if when is None:
        return None
    aware = when if when.tzinfo is not None else when.replace(tzinfo=UTC)
    return aware.astimezone(UTC).date()


class CategorySummary(BaseModel):
    """Spending and income totals for one category, within one currency.

    Sibling to :class:`CurrencySummary`, one level down: every
    :class:`CurrencySummary` carries a partition of its own totals by
    :func:`~traccio.domain.categories.effective_category`. There is no
    ``net`` here — unlike the currency level, nothing today consumes a
    signed per-category figure, and adding one with no caller would be
    speculative (see ``.claude/rules/python.md`` on YAGNI).

    Attributes
    ----------
    category_id : UUID or None
        The transaction's effective category, or ``None`` for the bucket of
        transactions with no category at all — a real, counted bucket, never
        silently dropped.
    spending : Money
        Total of every negative ``effective_amount`` in this category,
        negated to a positive magnitude.
    income : Money
        Total of every positive ``effective_amount`` in this category, a
        positive magnitude.
    transaction_count : int
        How many transactions fall in this category, regardless of whether
        they contributed to ``spending``, ``income``, or neither.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    category_id: UUID | None
    spending: Money
    income: Money
    transaction_count: int


class DaySummary(BaseModel):
    """Spending and income totals for one calendar day, within one currency.

    Sibling to :class:`CategorySummary`, one level down from
    :class:`CurrencySummary`. No ``net`` here either, same YAGNI reasoning as
    :class:`CategorySummary` — nothing today consumes a signed per-day figure.

    Attributes
    ----------
    day : date
        The UTC calendar day, from :func:`_day_of`.
    spending : Money
        Total of every negative ``effective_amount`` on this day, negated to a
        positive magnitude.
    income : Money
        Total of every positive ``effective_amount`` on this day, a positive
        magnitude.
    transaction_count : int
        How many transactions fall on this day, regardless of whether they
        contributed to ``spending``, ``income``, or neither.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    day: date
    spending: Money
    income: Money
    transaction_count: int


class CurrencySummary(BaseModel):
    """Spending and income totals for one currency over a period.

    ``spending`` and ``income`` are **positive magnitudes** — the same
    convention as :mod:`traccio.domain.advances` (``receivable``,
    ``outstanding``) — so they read naturally on a dashboard; ``net`` is the
    single **signed** figure, ``income - spending``.

    Attributes
    ----------
    currency : str
        ISO 4217 code this summary is expressed in. There is no FX in Traccio,
        so a period spanning multiple currencies produces one
        :class:`CurrencySummary` per currency rather than a single total.
    spending : Money
        Total of every negative ``effective_amount``, negated to a positive
        magnitude. A zero ``effective_amount`` (a transfer, a reimbursement, a
        rejected movement) contributes to neither ``spending`` nor ``income``.
    income : Money
        Total of every positive ``effective_amount``, a positive magnitude.
    net : Money
        ``income - spending``, signed.
    transaction_count : int
        How many transactions were considered for this currency, regardless of
        whether they contributed to ``spending``, ``income``, or neither.
    by_category : tuple[CategorySummary, ...]
        This currency's totals partitioned by
        :func:`~traccio.domain.categories.effective_category`. Sorted by
        ``spending`` descending, then ``income`` descending, then
        ``category_id`` for a deterministic order. Sums to this summary's own
        ``spending``/``income``/``transaction_count`` — never a separate
        total, since a category never spans currencies.
    by_day : tuple[DaySummary, ...]
        This currency's totals partitioned by UTC calendar day
        (:func:`_day_of`). Sorted chronologically. A transaction with neither
        ``booked_at`` nor ``value_date`` set is excluded here (there is no day
        to bucket it under) while still counted in this summary's own
        totals — the one place ``by_day`` does **not** sum back to the parent,
        unlike ``by_category``.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    currency: CurrencyCode
    spending: Money
    income: Money
    net: Money
    transaction_count: int
    by_category: tuple[CategorySummary, ...] = ()
    by_day: tuple[DaySummary, ...] = ()


def summarize(
    transactions: Sequence[Transaction],
    *,
    advance_shares: Mapping[UUID, Money] | None = None,
) -> list[CurrencySummary]:
    """Return spending/income summaries, one per currency, from ``effective_amount``.

    Groups transactions by currency — never sums across them, since Traccio
    does no FX conversion — and within each currency splits
    :func:`~traccio.domain.effective_amount.effective_amount` into the
    ``spending``/``income`` magnitudes and their signed ``net``. Mirrors
    :func:`~traccio.domain.events.event_total`'s resolution of an advance's
    signed share: the caller resolves ``advance_shares`` (typically via
    :func:`~traccio.services.advances.spending_shares`) and passes them in.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The transactions to summarize (already filtered to the period of
        interest by the caller — this function has no notion of "period").
    advance_shares : Mapping[UUID, Money] or None, optional
        For each member whose ``role`` is
        :attr:`~traccio.domain.enums.TransactionRole.ADVANCE`, its **signed**
        spending share, keyed by transaction id. Ignored for every other role.

    Returns
    -------
    list[CurrencySummary]
        One entry per currency present in ``transactions``, sorted by currency
        code for a deterministic result. Empty if ``transactions`` is empty.
        Each entry's ``by_category`` sums to that entry's own
        ``spending``/``income``/``transaction_count``; ``by_day`` sums to the
        same totals minus whatever had no ``booked_at``/``value_date`` at all.

    Raises
    ------
    ValueError
        If a member is an advance but its share is missing from
        ``advance_shares`` (propagated from ``effective_amount``). The message
        is stable and value-free.
    """
    shares = advance_shares or {}

    spending_by_currency: dict[str, int] = {}
    income_by_currency: dict[str, int] = {}
    count_by_currency: dict[str, int] = {}

    # Same three accumulators, one level down: keyed by (currency, category_id)
    # so a category never spans currencies (no FX in Traccio, ADR 0007).
    spending_by_category: dict[tuple[str, UUID | None], int] = {}
    income_by_category: dict[tuple[str, UUID | None], int] = {}
    count_by_category: dict[tuple[str, UUID | None], int] = {}

    # Same three accumulators again, keyed by (currency, day) — a day never
    # spans currencies either. A transaction with no day (see _day_of) simply
    # never touches these three dicts, so by_day naturally excludes it while
    # the currency/category totals above still count it.
    spending_by_day: dict[tuple[str, date], int] = {}
    income_by_day: dict[tuple[str, date], int] = {}
    count_by_day: dict[tuple[str, date], int] = {}

    for transaction in transactions:
        share = shares.get(transaction.id)
        effective = effective_amount(transaction, advance_own_share=share)
        currency = effective.currency
        category_id = effective_category(transaction)
        category_key = (currency, category_id)
        day = _day_of(transaction)
        day_key = (currency, day) if day is not None else None

        count_by_currency[currency] = count_by_currency.get(currency, 0) + 1
        count_by_category[category_key] = count_by_category.get(category_key, 0) + 1
        if day_key is not None:
            count_by_day[day_key] = count_by_day.get(day_key, 0) + 1
        if effective.amount < 0:
            spending_by_currency[currency] = (
                spending_by_currency.get(currency, 0) - effective.amount
            )
            spending_by_category[category_key] = (
                spending_by_category.get(category_key, 0) - effective.amount
            )
            if day_key is not None:
                spending_by_day[day_key] = spending_by_day.get(day_key, 0) - effective.amount
        elif effective.amount > 0:
            income_by_currency[currency] = income_by_currency.get(currency, 0) + effective.amount
            income_by_category[category_key] = (
                income_by_category.get(category_key, 0) + effective.amount
            )
            if day_key is not None:
                income_by_day[day_key] = income_by_day.get(day_key, 0) + effective.amount

    def _category_summaries(currency: str) -> tuple[CategorySummary, ...]:
        category_ids = {cid for (cur, cid) in count_by_category if cur == currency}
        entries = [
            CategorySummary(
                category_id=category_id,
                spending=Money(
                    amount=spending_by_category.get((currency, category_id), 0),
                    currency=currency,
                ),
                income=Money(
                    amount=income_by_category.get((currency, category_id), 0), currency=currency
                ),
                transaction_count=count_by_category[(currency, category_id)],
            )
            for category_id in category_ids
        ]
        # Biggest spender first, then biggest earner, then a deterministic
        # tiebreak — "no category" (None) is not comparable to a UUID, so the
        # sort key is built explicitly rather than relying on tuple ordering.
        entries.sort(key=lambda e: (-e.spending.amount, -e.income.amount, str(e.category_id or "")))
        return tuple(entries)

    def _day_summaries(currency: str) -> tuple[DaySummary, ...]:
        days = sorted({d for (cur, d) in count_by_day if cur == currency})
        return tuple(
            DaySummary(
                day=day,
                spending=Money(amount=spending_by_day.get((currency, day), 0), currency=currency),
                income=Money(amount=income_by_day.get((currency, day), 0), currency=currency),
                transaction_count=count_by_day[(currency, day)],
            )
            for day in days
        )

    currencies = set(count_by_currency)
    return [
        CurrencySummary(
            currency=currency,
            spending=Money(amount=spending_by_currency.get(currency, 0), currency=currency),
            income=Money(amount=income_by_currency.get(currency, 0), currency=currency),
            net=Money(
                amount=income_by_currency.get(currency, 0) - spending_by_currency.get(currency, 0),
                currency=currency,
            ),
            transaction_count=count_by_currency[currency],
            by_category=_category_summaries(currency),
            by_day=_day_summaries(currency),
        )
        for currency in sorted(currencies)
    ]
