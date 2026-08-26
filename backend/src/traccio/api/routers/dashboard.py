"""Dashboard endpoint router.

Answers M2's "done when" (``tasks/ROADMAP.md``): "I can tag a real advance
from a real trip and watch the dashboard show my actual share rather than the
full amount." Aggregates from ``effective_amount`` alone, never raw ``amount``
(see ``docs/architecture.md``).

Data safety (``.claude/rules/data-safety.md``): this handler logs only
currency codes, counts, and the requested granularity/timezone — never
amounts.
"""

from datetime import UTC, datetime, tzinfo
from typing import Annotated
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.dashboard import (
    AccountDisplay,
    CategoryDisplay,
    CurrencySummaryResponse,
    DashboardSummaryResponse,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    list_accounts,
    list_advances,
    list_categories,
    list_transactions_in_period,
    sum_reimbursements_by_advance,
)
from traccio.db.session import get_session
from traccio.domain.accounts import display_name
from traccio.domain.dashboard import summarize, summarize_comparisons
from traccio.domain.enums import BucketGranularity
from traccio.domain.models import Advance
from traccio.services.advances import spending_shares

logger = get_logger(__name__)

router = APIRouter()


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
) -> DashboardSummaryResponse:
    """Summarize real spending and income over a period, per currency.

    Uses only ``effective_amount`` (see :func:`~traccio.domain.dashboard.summarize`):
    a transfer between the user's own accounts does not inflate spending, an
    advance counts only the user's declared share, and a reimbursement is not
    income. There is no FX in Traccio, so a period spanning multiple currencies
    returns one entry per currency rather than a combined total. Scoped to the
    current user.

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

    Returns
    -------
    DashboardSummaryResponse
        One summary per currency present in the period.

    Raises
    ------
    HTTPException
        422 ``unknown_timezone`` if ``tz`` is not a recognized IANA name; 422
        ``incomplete_comparison_period`` if exactly one of
        ``compare_start``/``compare_end`` is given.
    """
    if (compare_start is None) != (compare_end is None):
        raise HTTPException(status_code=422, detail="incomplete_comparison_period")

    zone: tzinfo
    try:
        zone = ZoneInfo(tz)
    except ZoneInfoNotFoundError as exc:
        raise HTTPException(status_code=422, detail="unknown_timezone") from exc

    found = list_transactions_in_period(session, user_id, start=start, end=end)
    advance_by_tx: dict[UUID, Advance] = {
        advance.transaction_id: advance for advance in list_advances(session, user_id)
    }
    reimbursed_by_advance = sum_reimbursements_by_advance(session, user_id)
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

    now = datetime.now(UTC)
    summaries = summarize(
        found,
        advance_shares=shares,
        parents=parents,
        granularity=granularity,
        tz=zone,
        period_start=start,
        period_end=end,
        now=now,
    )

    if compare_start is not None and compare_end is not None:
        compare_found = list_transactions_in_period(
            session, user_id, start=compare_start, end=compare_end
        )
        compare_shares = spending_shares(
            compare_found, advance_by_tx=advance_by_tx, reimbursed=reimbursed_by_advance
        )
        compare_summaries = summarize(
            compare_found,
            advance_shares=compare_shares,
            parents=parents,
            granularity=granularity,
            tz=zone,
            period_start=compare_start,
            period_end=compare_end,
            now=now,
        )
        comparisons = summarize_comparisons(summaries, compare_summaries)
        summaries = [
            summary.model_copy(update={"comparison": comparisons.get(summary.currency)})
            for summary in summaries
        ]

    # Log currencies, a count, and the requested shape — never amounts (see
    # data-safety rules).
    logger.info(
        "dashboard.summary",
        currencies=[s.currency for s in summaries],
        count=len(found),
        granularity=granularity.value,
        has_comparison=compare_start is not None,
    )
    return DashboardSummaryResponse(
        currencies=[
            CurrencySummaryResponse.from_domain(
                s, category_display=category_display, account_display=account_display
            )
            for s in summaries
        ]
    )
