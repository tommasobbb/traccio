"""Request and response schemas for the dashboard endpoint.

The summary is **derived** from ``effective_amount`` alone by the pure
:mod:`traccio.domain.dashboard` functions, never stored — the client renders
it and never recomputes. A period spanning multiple currencies produces one
entry per currency (``currencies``); a single combined total converted into
one base currency is available **opt-in and additive** (``converted``,
ADR 0021, ``TRACCIO_FX_ENABLED``), never replacing the per-currency breakdown.

Category/account names, colours, and icons are read-time joins done here, not
carried on the domain summaries (``domain/`` never resolves a display value) —
:class:`CategoryDisplay`/:class:`AccountDisplay` are what
``api/routers/dashboard.py`` builds from a plain ``list_categories``/
``list_accounts`` call and passes into ``from_domain``.
"""

from collections.abc import Mapping
from datetime import date
from typing import NamedTuple
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.dashboard import (
    AccountSummary,
    BucketSummary,
    CategoryGroupSummary,
    CategorySummary,
    ComparisonSummary,
    CurrencySummary,
)
from traccio.domain.enums import AccountIcon, CategoryIcon, PaletteColor


class CategoryDisplay(NamedTuple):
    """A category's display fields, for the read-time join in this module.

    Attributes
    ----------
    name : str
        The category's current name.
    color : PaletteColor
        The category's colour (ADR 0017).
    icon : CategoryIcon or None
        The category's icon, or ``None`` if unset.
    """

    name: str
    color: PaletteColor
    icon: CategoryIcon | None


class AccountDisplay(NamedTuple):
    """An account's display fields, for the read-time join in this module.

    Attributes
    ----------
    name : str or None
        The account's resolved display name
        (:func:`~traccio.domain.accounts.display_name`), or ``None`` if
        neither an alias nor a provider name is set.
    color : PaletteColor or None
        The account's colour (ADR 0017), or ``None`` if unset.
    icon : AccountIcon or None
        The account's icon, or ``None`` if unset.
    """

    name: str | None
    color: PaletteColor | None
    icon: AccountIcon | None


class CategorySummaryResponse(BaseModel):
    """One child category's totals, nested inside a
    :class:`CategoryGroupSummaryResponse`.

    Attributes
    ----------
    category_id : UUID
        The child category's id.
    category_name : str or None
        The child's current name, resolved at read time. ``None`` only if the
        category was deleted between aggregation and this read — a rare race,
        degraded gracefully rather than raised.
    color : PaletteColor or None
        The child's colour, or ``None`` in the same rare race as
        ``category_name``.
    icon : CategoryIcon or None
        The child's icon, or ``None`` if unset (or the same race).
    spending : int
        Total spending in minor units (cents), a positive magnitude.
    income : int
        Total income in minor units (cents), a positive magnitude.
    transaction_count : int
        How many transactions carry this child category.
    """

    category_id: UUID
    category_name: str | None
    color: PaletteColor | None
    icon: CategoryIcon | None
    spending: int
    income: int
    transaction_count: int

    @classmethod
    def from_domain(
        cls, summary: CategorySummary, *, display: Mapping[UUID, CategoryDisplay]
    ) -> "CategorySummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.CategorySummary`."""
        info = display.get(summary.category_id)
        return cls(
            category_id=summary.category_id,
            category_name=info.name if info else None,
            color=info.color if info else None,
            icon=info.icon if info else None,
            spending=summary.spending.amount,
            income=summary.income.amount,
            transaction_count=summary.transaction_count,
        )


class CategoryGroupSummaryResponse(BaseModel):
    """One category root's totals, its children rolled up, as returned to the client.

    Attributes
    ----------
    category_id : UUID or None
        The root category's id, or ``None`` for the "no category" bucket.
    category_name : str or None
        The root's current name, resolved at read time. ``None`` iff
        ``category_id`` is ``None``, or the same delete race as
        :class:`CategorySummaryResponse`.
    color : PaletteColor or None
        The root's colour, or ``None`` iff ``category_id`` is ``None``.
    icon : CategoryIcon or None
        The root's icon, or ``None`` if unset (or ``category_id`` is
        ``None``).
    spending : int
        Total spending in minor units (cents), including every child — a
        positive magnitude.
    income : int
        Total income in minor units (cents), including every child.
    transaction_count : int
        Total transaction count, including every child.
    direct_spending : int
        Spending from transactions on the root itself, excluding any child.
    direct_income : int
        Income from transactions on the root itself, excluding any child.
    direct_transaction_count : int
        Transaction count on the root itself, excluding any child.
    children : list[CategorySummaryResponse]
        This root's children with at least one transaction, sorted by
        spending then income descending.
    """

    category_id: UUID | None
    category_name: str | None
    color: PaletteColor | None
    icon: CategoryIcon | None
    spending: int
    income: int
    transaction_count: int
    direct_spending: int
    direct_income: int
    direct_transaction_count: int
    children: list[CategorySummaryResponse]

    @classmethod
    def from_domain(
        cls, group: CategoryGroupSummary, *, display: Mapping[UUID, CategoryDisplay]
    ) -> "CategoryGroupSummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.CategoryGroupSummary`."""
        info = None if group.category_id is None else display.get(group.category_id)
        return cls(
            category_id=group.category_id,
            category_name=info.name if info else None,
            color=info.color if info else None,
            icon=info.icon if info else None,
            spending=group.spending.amount,
            income=group.income.amount,
            transaction_count=group.transaction_count,
            direct_spending=group.direct_spending.amount,
            direct_income=group.direct_income.amount,
            direct_transaction_count=group.direct_transaction_count,
            children=[
                CategorySummaryResponse.from_domain(child, display=display)
                for child in group.children
            ],
        )


class BucketSummaryResponse(BaseModel):
    """Spending and income totals for one time bucket, as returned to the client.

    Attributes
    ----------
    start : date
        The bucket's start, a local calendar date.
    end : date
        The bucket's exclusive end.
    spending : int
        Total spending in minor units (cents), a positive magnitude.
    income : int
        Total income in minor units (cents), a positive magnitude.
    transaction_count : int
        How many transactions fall in this bucket.
    """

    start: date
    end: date
    spending: int
    income: int
    transaction_count: int

    @classmethod
    def from_domain(cls, summary: BucketSummary) -> "BucketSummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.BucketSummary`."""
        return cls(
            start=summary.start,
            end=summary.end,
            spending=summary.spending.amount,
            income=summary.income.amount,
            transaction_count=summary.transaction_count,
        )


class AccountSummaryResponse(BaseModel):
    """Spending and income totals for one account, as returned to the client.

    Attributes
    ----------
    account_id : UUID
        The account these totals belong to.
    account_name : str or None
        The account's resolved display name, or ``None`` if unset or the
        account was deleted between aggregation and this read.
    color : PaletteColor or None
        The account's colour, or ``None`` if unset (or the same race).
    icon : AccountIcon or None
        The account's icon, or ``None`` if unset (or the same race).
    spending : int
        Total spending in minor units (cents), a positive magnitude.
    income : int
        Total income in minor units (cents), a positive magnitude.
    transaction_count : int
        How many transactions fall on this account.
    """

    account_id: UUID
    account_name: str | None
    color: PaletteColor | None
    icon: AccountIcon | None
    spending: int
    income: int
    transaction_count: int

    @classmethod
    def from_domain(
        cls, summary: AccountSummary, *, display: Mapping[UUID, AccountDisplay]
    ) -> "AccountSummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.AccountSummary`."""
        info = display.get(summary.account_id)
        return cls(
            account_id=summary.account_id,
            account_name=info.name if info else None,
            color=info.color if info else None,
            icon=info.icon if info else None,
            spending=summary.spending.amount,
            income=summary.income.amount,
            transaction_count=summary.transaction_count,
        )


class ComparisonSummaryResponse(BaseModel):
    """The comparison period's totals and the delta, as returned to the client.

    Attributes
    ----------
    spending : int
        The comparison period's own spending in minor units (cents).
    income : int
        The comparison period's own income in minor units (cents).
    net : int
        The comparison period's own net, signed, minor units.
    spending_delta : int
        Current period's spending minus the comparison period's, signed,
        minor units.
    spending_delta_pct : float or None
        ``spending_delta`` as a fraction of the comparison period's spending,
        or ``None`` when that spending was zero. The one float in this
        schema — a ratio, not money.
    """

    spending: int
    income: int
    net: int
    spending_delta: int
    spending_delta_pct: float | None

    @classmethod
    def from_domain(cls, summary: ComparisonSummary) -> "ComparisonSummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.ComparisonSummary`."""
        return cls(
            spending=summary.spending.amount,
            income=summary.income.amount,
            net=summary.net.amount,
            spending_delta=summary.spending_delta.amount,
            spending_delta_pct=summary.spending_delta_pct,
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
    average_daily_spending : int or None
        ``spending`` divided by elapsed days in the period, minor units. See
        ``domain/dashboard.py::_average_daily_spending`` for when it is
        ``None``.
    by_category : list[CategoryGroupSummaryResponse]
        This currency's totals partitioned by category root, each with its
        children rolled up. Sums to this entry's own totals.
    by_bucket : list[BucketSummaryResponse]
        This currency's totals partitioned by time bucket, gap-filled across
        the requested period when both ``start`` and ``end`` were given. A
        transaction with neither ``booked_at`` nor ``value_date`` set is
        excluded here while still counted in this entry's own totals.
    by_account : list[AccountSummaryResponse]
        This currency's totals partitioned by account. Sums to this entry's
        own totals.
    comparison : ComparisonSummaryResponse or None
        The comparison period's totals and the delta, or ``None`` when
        ``compare_start``/``compare_end`` were not both supplied.
    """

    currency: str
    spending: int
    income: int
    net: int
    transaction_count: int
    average_daily_spending: int | None
    by_category: list[CategoryGroupSummaryResponse]
    by_bucket: list[BucketSummaryResponse]
    by_account: list[AccountSummaryResponse]
    comparison: ComparisonSummaryResponse | None

    @classmethod
    def from_domain(
        cls,
        summary: CurrencySummary,
        *,
        category_display: Mapping[UUID, CategoryDisplay],
        account_display: Mapping[UUID, AccountDisplay],
    ) -> "CurrencySummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.CurrencySummary`."""
        return cls(
            currency=summary.currency,
            spending=summary.spending.amount,
            income=summary.income.amount,
            net=summary.net.amount,
            transaction_count=summary.transaction_count,
            average_daily_spending=(
                None
                if summary.average_daily_spending is None
                else summary.average_daily_spending.amount
            ),
            by_category=[
                CategoryGroupSummaryResponse.from_domain(group, display=category_display)
                for group in summary.by_category
            ],
            by_bucket=[BucketSummaryResponse.from_domain(bucket) for bucket in summary.by_bucket],
            by_account=[
                AccountSummaryResponse.from_domain(account, display=account_display)
                for account in summary.by_account
            ],
            comparison=(
                None
                if summary.comparison is None
                else ComparisonSummaryResponse.from_domain(summary.comparison)
            ),
        )


class MealVoucherSummaryResponse(BaseModel):
    """Meal-voucher spending for one currency, broken out of the headline
    totals (ADR 0029).

    Built from the same :func:`~traccio.domain.dashboard.summarize` as
    :class:`CurrencySummaryResponse`, run once over the transactions on the
    user's voucher-kind accounts instead of everything else — a scoping
    split, not a second derivation. Omitted (empty ``meal_vouchers`` on
    :class:`DashboardSummaryResponse`) when the setting is off, there is no
    voucher account, or nothing was spent from one this period.

    Attributes
    ----------
    currency : str
        ISO 4217 code this entry is expressed in.
    spending : int
        Total voucher spending in minor units (cents), a positive magnitude.
    income : int
        Total voucher income in minor units (cents) — a refund onto a
        voucher account, a positive magnitude. Rare, but not excluded.
    transaction_count : int
        How many voucher transactions were considered for this currency.
    by_category : list[CategoryGroupSummaryResponse]
        This currency's voucher spending partitioned by category root, same
        shape as :attr:`CurrencySummaryResponse.by_category`.
    """

    currency: str
    spending: int
    income: int
    transaction_count: int
    by_category: list[CategoryGroupSummaryResponse]

    @classmethod
    def from_domain(
        cls, summary: CurrencySummary, *, category_display: Mapping[UUID, CategoryDisplay]
    ) -> "MealVoucherSummaryResponse":
        """Project a domain :class:`~traccio.domain.dashboard.CurrencySummary`."""
        return cls(
            currency=summary.currency,
            spending=summary.spending.amount,
            income=summary.income.amount,
            transaction_count=summary.transaction_count,
            by_category=[
                CategoryGroupSummaryResponse.from_domain(group, display=category_display)
                for group in summary.by_category
            ],
        )


class FxRateResponse(BaseModel):
    """One ECB reference rate used to build the converted total (ADR 0021).

    Attributes
    ----------
    source_currency : str
        The currency this rate converts *from*.
    rate : str
        The multiplier as an exact decimal string (``source_currency`` amount
        times this yields the base currency).
    rate_date : date
        The ECB publication date the rate is for — a movement is converted at
        the rate on or before its own date.
    """

    source_currency: str
    rate: str
    rate_date: date


class ConvertedSummaryResponse(BaseModel):
    """The opt-in combined total, every currency converted into one base.

    Present only when ``TRACCIO_FX_ENABLED`` is set and every currency the
    period contains could be converted; otherwise ``DashboardSummaryResponse.converted``
    is ``null`` and ``conversion_unavailable`` says why. Additive — the
    per-currency ``currencies`` breakdown is unchanged and remains the source
    of truth (ADR 0021).

    Attributes
    ----------
    summary : CurrencySummaryResponse
        A normal currency summary whose ``currency`` is the base currency and
        whose totals sum every movement, each converted at its own date's
        rate. ``by_category``/``by_bucket``/``by_account``/``comparison`` are
        all converted too.
    rates : list[FxRateResponse]
        The distinct (source currency, rate, date) triples actually used, for
        provenance.
    basis : str
        Always ``"historical"`` — each movement converted at the rate for its
        effective date, a dateless movement at the latest rate.
    """

    summary: CurrencySummaryResponse
    rates: list[FxRateResponse]
    basis: str = "historical"


class DashboardSummaryResponse(BaseModel):
    """Envelope for the dashboard summary.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    currencies : list[CurrencySummaryResponse]
        One entry per currency present in the period, sorted by currency code.
        Empty if no transactions fall within the period.
    converted : ConvertedSummaryResponse or None
        The opt-in combined total in the base currency (ADR 0021), or ``null``
        when the feature is off or a rate was missing. Additive — never a
        replacement for ``currencies``.
    conversion_unavailable : str or None
        When ``TRACCIO_FX_ENABLED`` is set but ``converted`` is still ``null``,
        a stable value-free reason (``"rates_unavailable"`` / ``"missing_rate"``).
        ``null`` when the feature is off or conversion succeeded.
    meal_vouchers : list[MealVoucherSummaryResponse]
        Meal-voucher spending, broken out of ``currencies``/``converted``
        (ADR 0029). Empty when the user's ``meal_vouchers_enabled`` setting
        is off, they have no voucher-kind account, or nothing was spent from
        one this period. Never FX-converted — a per-currency breakout,
        additive, like ``currencies`` itself.
    """

    currencies: list[CurrencySummaryResponse]
    converted: ConvertedSummaryResponse | None = None
    meal_vouchers: list[MealVoucherSummaryResponse] = []
    conversion_unavailable: str | None = None
