"""Dashboard endpoint router.

Answers M2's "done when" (``tasks/ROADMAP.md``): "I can tag a real advance
from a real trip and watch the dashboard show my actual share rather than the
full amount." Aggregates from ``effective_amount`` alone, never raw ``amount``
(see ``docs/architecture.md``).

Data safety (``.claude/rules/data-safety.md``): this handler logs only
currency codes, counts, and the requested granularity/timezone — never
amounts.
"""

from collections.abc import Callable, Mapping, Sequence
from datetime import UTC, date, datetime, time, tzinfo
from typing import Annotated
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from traccio.api.deps import (
    current_meal_vouchers_enabled,
    current_tracking_start,
    current_user_id,
    get_fx_client,
)
from traccio.api.schemas.dashboard import (
    AccountDisplay,
    CategoryDisplay,
    ConvertedSummaryResponse,
    CurrencySummaryResponse,
    DashboardSummaryResponse,
    FxRateResponse,
    MealVoucherSummaryResponse,
)
from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    get_fx_rates,
    list_accounts,
    list_categories,
    list_transactions_in_period,
)
from traccio.db.session import get_session
from traccio.domain.accounts import display_name
from traccio.domain.dashboard import (
    CurrencySummary,
    split_meal_voucher_transactions,
    summarize,
    summarize_comparisons,
)
from traccio.domain.enums import AccountKind, BucketGranularity
from traccio.domain.fx import MissingRate, to_base_currency
from traccio.domain.models import Transaction
from traccio.domain.money import Money
from traccio.providers.frankfurter import FrankfurterClient
from traccio.services.advance_shares import fetch_advance_pool
from traccio.services.advances import spending_shares
from traccio.services.fx import FxUnavailable, build_rate_resolver

logger = get_logger(__name__)

router = APIRouter()

_SummarizePeriod = Callable[
    [Sequence[Transaction], Mapping[UUID, Money], Sequence[Transaction], Mapping[UUID, Money]],
    list[CurrencySummary],
]


def _build_converted(
    session: Session,
    fx_client: FrankfurterClient | None,
    *,
    found: Sequence[Transaction],
    shares: Mapping[UUID, Money],
    compare_found: Sequence[Transaction],
    compare_shares: Mapping[UUID, Money],
    summarize_period: _SummarizePeriod,
    category_display: Mapping[UUID, CategoryDisplay],
    account_display: Mapping[UUID, AccountDisplay],
    now: datetime,
) -> tuple[ConvertedSummaryResponse | None, str | None]:
    """Build the opt-in converted combined total (ADR 0021), or explain why not.

    Returns ``(None, None)`` when the feature is off or the period is empty;
    ``(None, reason)`` when a rate could not be obtained; ``(response, None)``
    on success. Conversion happens **before** ``summarize``: every movement's
    ``Money`` (and advance share) is rewritten into the base currency at its
    own date's rate, then the same ``summarize_period`` closure runs over the
    rewritten inputs — so the converted summary carries the same
    ``by_category``/``by_bucket``/``by_account``/``comparison`` shape, all in
    the base currency.
    """
    if fx_client is None or not found:
        return None, None

    settings = get_settings()
    base = settings.fx_base_currency

    resolver = build_rate_resolver(
        session,
        fx_client,
        base=base,
        transactions=[*found, *compare_found],
        now=now,
        ttl_hours=settings.fx_rate_ttl_hours,
    )
    if isinstance(resolver, FxUnavailable):
        return None, resolver.reason

    base_input = to_base_currency(found, shares, base=base, rate_for=resolver)
    if isinstance(base_input, MissingRate):
        return None, "missing_rate"
    cmp_input = to_base_currency(compare_found, compare_shares, base=base, rate_for=resolver)
    if isinstance(cmp_input, MissingRate):
        return None, "missing_rate"

    converted_summaries = summarize_period(
        base_input.transactions,
        base_input.advance_shares,
        cmp_input.transactions,
        cmp_input.advance_shares,
    )
    if not converted_summaries:
        return None, None

    summary_response = CurrencySummaryResponse.from_domain(
        converted_summaries[0],
        category_display=category_display,
        account_display=account_display,
    )

    non_base = sorted(
        {t.money.currency for t in [*found, *compare_found] if t.money.currency != base}
    )
    rates: list[FxRateResponse] = []
    for currency in non_base:
        cached = get_fx_rates(
            session, base=base, quotes=[currency], up_to=now.astimezone(UTC).date()
        )
        if cached:
            newest = cached[-1]
            rates.append(
                FxRateResponse(
                    source_currency=currency,
                    rate=str(newest.rate),
                    rate_date=newest.rate_date,
                )
            )

    return ConvertedSummaryResponse(summary=summary_response, rates=rates), None


@router.get("/dashboard/summary", response_model=DashboardSummaryResponse)
def dashboard_summary(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    start: Annotated[datetime | None, Query()] = None,
    end: Annotated[datetime | None, Query()] = None,
    granularity: Annotated[BucketGranularity, Query()] = BucketGranularity.DAY,
    tz: Annotated[str, Query()] = "UTC",
    compare_start: Annotated[datetime | None, Query()] = None,
    compare_end: Annotated[datetime | None, Query()] = None,
    tracking_start: Annotated[date | None, Depends(current_tracking_start)] = None,
    fx_client: Annotated[FrankfurterClient | None, Depends(get_fx_client)] = None,
    meal_vouchers_enabled: Annotated[bool, Depends(current_meal_vouchers_enabled)] = False,
) -> DashboardSummaryResponse:
    """Summarize real spending and income over a period, per currency.

    Uses only ``effective_amount`` (see :func:`~traccio.domain.dashboard.summarize`):
    a transfer between the user's own accounts does not inflate spending, an
    advance counts only the user's declared share, and a reimbursement is not
    income. A period spanning multiple currencies returns one entry per
    currency in ``currencies``; when ``TRACCIO_FX_ENABLED`` is set,
    ``converted`` additionally carries a single combined total in the base
    currency, each movement converted at the ECB rate for its own date
    (ADR 0021) — best-effort, ``null`` with a ``conversion_unavailable``
    reason if a rate is missing. Scoped to the current user.

    When ``start``/``end`` are both given, ``by_bucket`` is gap-filled across
    the whole period (zero-value buckets included); otherwise only buckets
    with a transaction are returned, same as the pre-gap-fill behavior.
    ``compare_start``/``compare_end`` must both be given or both omitted — the
    client names *which* period to compare against, not a boolean, since
    "same length, shifted back" is not well-defined across calendar
    boundaries (a fixed-length shift lands on an arbitrary date, not "last
    month").

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose transactions to summarize.
    start : datetime or None, optional
        Inclusive start of the period. Open-ended when omitted.
    end : datetime or None, optional
        Exclusive end of the period. Open-ended when omitted.
    granularity : BucketGranularity, optional
        How ``by_bucket`` groups time — day, week, or month. Defaults to day.
    tz : str, optional
        IANA timezone name bucketing happens in. Defaults to ``"UTC"``.
    compare_start : datetime or None, optional
        Inclusive start of the comparison period.
    compare_end : datetime or None, optional
        Exclusive end of the comparison period.
    tracking_start : date or None
        Not a query param — the user's stored ``tracking_start_date`` floor
        (ADR 0024), injected via
        :func:`~traccio.api.deps.current_tracking_start`. Raised into both the
        main and the comparison period before anything is fetched or bucketed,
        so no total, bucket, or average counts a day the user excluded.
    meal_vouchers_enabled : bool
        Not a query param — the user's stored ``meal_vouchers_enabled``
        setting (ADR 0029), injected via
        :func:`~traccio.api.deps.current_meal_vouchers_enabled`. When set,
        every voucher-kind account's spending is excluded from ``currencies``/
        ``converted`` and reported separately in ``meal_vouchers`` instead.

    Returns
    -------
    DashboardSummaryResponse
        One summary per currency present in the period, plus the meal-voucher
        breakout when the setting is on and there is voucher spend.

    Raises
    ------
    HTTPException
        422 ``unknown_timezone`` if ``tz`` is not a recognized IANA name; 422
        ``incomplete_comparison_period`` if exactly one of
        ``compare_start``/``compare_end`` is given.
    """
    if (compare_start is None) != (compare_end is None):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="incomplete_comparison_period"
        )

    zone: tzinfo
    try:
        zone = ZoneInfo(tz)
    except ZoneInfoNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="unknown_timezone"
        ) from exc

    # The tracking-start floor (ADR 0024) is raised into the requested period
    # *here*, so the same clamped start drives both the transaction fetch and
    # ``summarize``'s bucket grid / average-daily-spending — clamping only the
    # query would leave empty leading buckets and a wrong daily average.
    def _clamp(value: datetime | None) -> datetime | None:
        if tracking_start is None:
            return value
        floor = datetime.combine(tracking_start, time.min, tzinfo=UTC)
        return floor if value is None else max(value, floor)

    start = _clamp(start)
    if compare_start is not None and compare_end is not None:
        compare_start = _clamp(compare_start)

    found = list_transactions_in_period(session, user_id, start=start, end=end)
    # Fetched once, not once per period: the comparison period below reuses
    # the same advance_by_tx/reimbursed_by_advance pair.
    advance_by_tx, reimbursed_by_advance = fetch_advance_pool(session, user_id=user_id)
    shares = spending_shares(found, advance_by_tx=advance_by_tx, reimbursed=reimbursed_by_advance)

    categories = list_categories(session, user_id)
    parents = {category.id: category.parent_id for category in categories}
    category_display = {
        category.id: CategoryDisplay(name=category.name, color=category.color, icon=category.icon)
        for category in categories
    }

    accounts = list_accounts(session, user_id)
    account_display = {
        account.id: AccountDisplay(
            name=display_name(account), color=account.color, icon=account.icon
        )
        for account in accounts
    }

    # A scoping filter, not a second derivation from ``effective_amount`` —
    # same class of thing as the tracking-start floor above: voucher
    # transactions are removed before anything downstream (totals, FX
    # conversion, the comparison) ever sees them, and reported separately
    # from their own ``summarize`` call instead (ADR 0029).
    voucher_account_ids = (
        {account.id for account in accounts if account.kind is AccountKind.VOUCHER}
        if meal_vouchers_enabled
        else set()
    )
    found, voucher_found = split_meal_voucher_transactions(
        found, voucher_account_ids=voucher_account_ids
    )

    now = datetime.now(UTC)

    comparing = compare_start is not None and compare_end is not None
    compare_found: list[Transaction] = []
    compare_shares: dict[UUID, Money] = {}
    if comparing:
        compare_found = list_transactions_in_period(
            session, user_id, start=compare_start, end=compare_end
        )
        compare_found, _ = split_meal_voucher_transactions(
            compare_found, voucher_account_ids=voucher_account_ids
        )
        compare_shares = spending_shares(
            compare_found, advance_by_tx=advance_by_tx, reimbursed=reimbursed_by_advance
        )

    def summarize_period(
        txns: Sequence[Transaction],
        txn_shares: Mapping[UUID, Money],
        cmp_txns: Sequence[Transaction],
        cmp_shares: Mapping[UUID, Money],
    ) -> list[CurrencySummary]:
        """Run ``summarize`` for the period and, if requested, attach the comparison."""
        result = summarize(
            txns,
            advance_shares=txn_shares,
            parents=parents,
            granularity=granularity,
            tz=zone,
            period_start=start,
            period_end=end,
            now=now,
        )
        if not comparing:
            return result
        cmp = summarize(
            cmp_txns,
            advance_shares=cmp_shares,
            parents=parents,
            granularity=granularity,
            tz=zone,
            period_start=compare_start,
            period_end=compare_end,
            now=now,
        )
        deltas = summarize_comparisons(result, cmp)
        return [s.model_copy(update={"comparison": deltas.get(s.currency)}) for s in result]

    summaries = summarize_period(found, shares, compare_found, compare_shares)

    converted, conversion_unavailable = _build_converted(
        session,
        fx_client,
        found=found,
        shares=shares,
        compare_found=compare_found,
        compare_shares=compare_shares,
        summarize_period=summarize_period,
        category_display=category_display,
        account_display=account_display,
        now=now,
    )
    # The only write on this otherwise read-only GET: build_rate_resolver may
    # have cached a newly fetched FX rate (services/fx.py does not commit —
    # the caller owns the transaction boundary, same convention as sync.py).
    session.commit()

    # The voucher breakout: one more (uncompared) ``summarize`` call over the
    # transactions the split above set aside, never FX-converted (ADR 0029
    # keeps it a per-currency breakout, additive like ``currencies``).
    voucher_summaries = (
        summarize(
            voucher_found,
            advance_shares=shares,
            parents=parents,
            granularity=granularity,
            tz=zone,
            period_start=start,
            period_end=end,
            now=now,
        )
        if voucher_found
        else []
    )

    # Log currencies, a count, and the requested shape — never amounts (see
    # data-safety rules).
    logger.info(
        "dashboard.summary",
        currencies=[s.currency for s in summaries],
        count=len(found),
        granularity=granularity.value,
        has_comparison=comparing,
        converted=converted is not None,
        conversion_unavailable=conversion_unavailable,
        meal_voucher_count=len(voucher_found),
    )
    return DashboardSummaryResponse(
        currencies=[
            CurrencySummaryResponse.from_domain(
                s, category_display=category_display, account_display=account_display
            )
            for s in summaries
        ],
        converted=converted,
        conversion_unavailable=conversion_unavailable,
        meal_vouchers=[
            MealVoucherSummaryResponse.from_domain(s, category_display=category_display)
            for s in voucher_summaries
        ],
    )
