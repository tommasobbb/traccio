"""Dashboard endpoint router.

Answers M2's "done when" (``tasks/ROADMAP.md``): "I can tag a real advance
from a real trip and watch the dashboard show my actual share rather than the
full amount." Aggregates from ``effective_amount`` alone, never raw ``amount``
(see ``docs/architecture.md``).

Data safety (``.claude/rules/data-safety.md``): this handler logs only
currency codes and counts — never amounts.
"""

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.dashboard import CurrencySummaryResponse, DashboardSummaryResponse
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    list_advances,
    list_categories,
    list_transactions_in_period,
    sum_reimbursements_by_advance,
)
from traccio.db.session import get_session
from traccio.domain.dashboard import summarize
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
) -> DashboardSummaryResponse:
    """Summarize real spending and income over a period, per currency.

    Uses only ``effective_amount`` (see :func:`~traccio.domain.dashboard.summarize`):
    a transfer between the user's own accounts does not inflate spending, an
    advance counts only the user's declared share, and a reimbursement is not
    income. There is no FX in Traccio, so a period spanning multiple currencies
    returns one entry per currency rather than a combined total. Scoped to the
    current user.

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

    Returns
    -------
    DashboardSummaryResponse
        One summary per currency present in the period.
    """
    found = list_transactions_in_period(session, user_id, start=start, end=end)
    advance_by_tx: dict[UUID, Advance] = {
        advance.transaction_id: advance for advance in list_advances(session, user_id)
    }
    reimbursed_by_advance = sum_reimbursements_by_advance(session, user_id)
    shares = spending_shares(found, advance_by_tx=advance_by_tx, reimbursed=reimbursed_by_advance)

    summaries = summarize(found, advance_shares=shares)

    # Category names are a read-time join for display, not a domain
    # derivation — the aggregation itself only ever handles category ids
    # (see domain/dashboard.py). Never logged: user-typed text.
    category_names = {category.id: category.name for category in list_categories(session, user_id)}

    # Log currencies and a count, never amounts (see data-safety rules).
    logger.info(
        "dashboard.summary", currencies=[s.currency for s in summaries], count=len(found)
    )
    return DashboardSummaryResponse(
        currencies=[
            CurrencySummaryResponse.from_domain(s, category_names=category_names)
            for s in summaries
        ]
    )
