"""Transfer-suggestions endpoint router."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.transfers import TransferSuggestionResponse, TransferSuggestionsResponse
from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.repositories import list_all_transactions
from traccio.db.session import get_session
from traccio.services.transfers import detect_transfers

logger = get_logger(__name__)

router = APIRouter()


@router.get("/transfers/suggestions", response_model=TransferSuggestionsResponse)
def transfer_suggestions(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> TransferSuggestionsResponse:
    """Suggest transfers among the current user's transactions.

    Computed on demand and **read-only**: detection only proposes pairs, it never
    links them (``docs/architecture.md``). The user confirms a suggestion later,
    which is a separate, explicit action. Scoped to the current user; the
    tolerance and window come from settings.

    Parameters
    ----------
    session : Session
        Request-scoped database session (see :func:`get_session`).
    user_id : UUID
        The user whose transactions to search.

    Returns
    -------
    TransferSuggestionsResponse
        The suggested transfers, most confident first (empty if none).
    """
    settings = get_settings()
    transactions = list_all_transactions(session, user_id)
    suggestions = detect_transfers(
        transactions,
        amount_tolerance_cents=settings.transfer_amount_tolerance_cents,
        window_days=settings.transfer_window_days,
    )
    # Log a count, never transaction contents (see data-safety rules).
    logger.info("transfers.suggestions", count=len(suggestions))
    return TransferSuggestionsResponse(
        suggestions=[TransferSuggestionResponse.from_domain(s) for s in suggestions]
    )
