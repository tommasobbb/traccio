"""Request and response schemas for the dashboard endpoint.

The summary is **derived** from ``effective_amount`` alone by the one pure
:func:`~traccio.domain.dashboard.summarize` function, never stored — the client
renders it and never recomputes. There is no FX in Traccio, so a period
spanning multiple currencies produces one entry per currency rather than a
single combined total.
"""

from collections.abc import Mapping
from datetime import date
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.dashboard import CategorySummary, CurrencySummary, DaySummary


class CategorySummaryResponse(BaseModel):
    """Spending and income totals for one category, as returned to the client.

    Attributes
    ----------
    category_id : UUID or None
        The category this entry is for, or ``None`` for the "no category"
        bucket — a real, counted entry, never omitted.
    category_name : str or None
        The category's current name, resolved by the router at read time (not
        stored on the domain summary — see
        ``api/routers/dashboard.py``). ``None`` iff ``category_id`` is
        ``None``.
    spending : int
        Total spending in minor units (cents), a positive magnitude.
    income : int
        Total income in minor units (cents), a positive magnitude.
    transaction_count : int
        How many transactions fall in this category.
    """

    category_id: UUID | None
    category_name: str | None
    spending: int
    income: int
    transaction_count: int

    @classmethod
    def from_domain(
        cls, summary: CategorySummary, *, category_names: Mapping[UUID, str]
    ) -> "CategorySummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.CategorySummary`.

        Parameters
        ----------
        summary : CategorySummary
            The pure aggregation result for one category.
        category_names : Mapping[UUID, str]
            The current user's category names, keyed by id — resolved by the
            router (a repository read), never looked up here. A
            ``category_id`` absent from this mapping (deleted between the
            aggregation and the read) falls back to ``None`` rather than
            raising, same posture as any other best-effort display join.
        """
        name = None if summary.category_id is None else category_names.get(summary.category_id)
        return cls(
            category_id=summary.category_id,
            category_name=name,
            spending=summary.spending.amount,
            income=summary.income.amount,
            transaction_count=summary.transaction_count,
        )


class DaySummaryResponse(BaseModel):
    """Spending and income totals for one calendar day, as returned to the client.

    Attributes
    ----------
    date : date
        The UTC calendar day this entry is for.
    spending : int
        Total spending in minor units (cents), a positive magnitude.
    income : int
        Total income in minor units (cents), a positive magnitude.
    transaction_count : int
        How many transactions fall on this day.
    """

    date: date
    spending: int
    income: int
    transaction_count: int

    @classmethod
    def from_domain(cls, summary: DaySummary) -> "DaySummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.DaySummary`."""
        return cls(
            date=summary.day,
            spending=summary.spending.amount,
            income=summary.income.amount,
            transaction_count=summary.transaction_count,
        )


class CurrencySummaryResponse(BaseModel):
    """Spending and income totals for one currency, as returned to the client.

    Attributes
    ----------
    currency : str
        ISO 4217 code this summary is expressed in.
    spending : int
        Total spending in minor units (cents), a positive magnitude — the sum
        of every negative ``effective_amount``, negated.
    income : int
        Total income in minor units (cents), a positive magnitude — the sum of
        every positive ``effective_amount``.
    net : int
        ``income - spending`` in minor units (cents), signed.
    transaction_count : int
        How many transactions were considered for this currency.
    by_category : list[CategorySummaryResponse]
        This currency's totals partitioned by category, sorted by spending
        then income descending. Sums to this entry's own
        ``spending``/``income``/``transaction_count``.
    by_day : list[DaySummaryResponse]
        This currency's totals partitioned by UTC calendar day, sorted
        chronologically. A transaction with neither ``booked_at`` nor
        ``value_date`` set is excluded here while still counted in this
        entry's own totals — the one field that does not sum back to the
        parent, unlike ``by_category``.
    """

    currency: str
    spending: int
    income: int
    net: int
    transaction_count: int
    by_category: list[CategorySummaryResponse]
    by_day: list[DaySummaryResponse]

    @classmethod
    def from_domain(
        cls, summary: CurrencySummary, *, category_names: Mapping[UUID, str]
    ) -> "CurrencySummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.CurrencySummary`."""
        return cls(
            currency=summary.currency,
            spending=summary.spending.amount,
            income=summary.income.amount,
            net=summary.net.amount,
            transaction_count=summary.transaction_count,
            by_category=[
                CategorySummaryResponse.from_domain(entry, category_names=category_names)
                for entry in summary.by_category
            ],
            by_day=[DaySummaryResponse.from_domain(entry) for entry in summary.by_day],
        )


class DashboardSummaryResponse(BaseModel):
    """Envelope for the dashboard summary.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    currencies : list[CurrencySummaryResponse]
        One entry per currency present in the period, sorted by currency code.
        Empty if no transactions fall within the period.
    """

    currencies: list[CurrencySummaryResponse]
