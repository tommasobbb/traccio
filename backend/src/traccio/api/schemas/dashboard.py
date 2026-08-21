"""Request and response schemas for the dashboard endpoint.

The summary is **derived** from ``effective_amount`` alone by the one pure
:func:`~traccio.domain.dashboard.summarize` function, never stored — the client
renders it and never recomputes. There is no FX in Traccio, so a period
spanning multiple currencies produces one entry per currency rather than a
single combined total.
"""

from pydantic import BaseModel

from traccio.domain.dashboard import CurrencySummary


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
    """

    currency: str
    spending: int
    income: int
    net: int
    transaction_count: int

    @classmethod
    def from_domain(cls, summary: CurrencySummary) -> "CurrencySummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.CurrencySummary`."""
        return cls(
            currency=summary.currency,
            spending=summary.spending.amount,
            income=summary.income.amount,
            net=summary.net.amount,
            transaction_count=summary.transaction_count,
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
