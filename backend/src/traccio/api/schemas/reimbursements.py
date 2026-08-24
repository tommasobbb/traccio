"""Request and response schemas for the reimbursement endpoints.

A reimbursement records money paid back against an :class:`Advance`. Its
``amount`` is a positive magnitude (cents) in the advance's currency; a
reimbursement is either a linked incoming transaction or a manual cash entry
(``transaction_id`` absent). The advance's derived ``outstanding``/``status``
follow from the sum of reimbursements (see :mod:`traccio.domain.advances`) and
are returned on the advance schema, not here.
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.models import Reimbursement


class CreateReimbursementRequest(BaseModel):
    """Body for recording a reimbursement against an advance.

    Attributes
    ----------
    amount : int
        The amount paid back, a positive magnitude in the advance's currency
        (cents); must be ``> 0``.
    transaction_id : UUID or None
        The incoming transaction to link (the caller's, a ``personal``
        non-``rejected`` credit). Omit for a manual cash reimbursement.
    participant_id : UUID or None
        The participant this reimbursement is attributed to (ADR 0012). Must
        be one of the advance's own participants, or the router rejects it
        with a ``404 unknown_participant``. Omit to leave it unattributed —
        the only option before ADR 0012, still fully supported.
    note : str or None
        Optional free-text note.
    """

    amount: int
    transaction_id: UUID | None = None
    participant_id: UUID | None = None
    note: str | None = None


class ReimbursementResponse(BaseModel):
    """One reimbursement as returned to the client.

    Projects :class:`~traccio.domain.models.Reimbursement`. Amounts are positive
    magnitudes in the advance's currency.

    Attributes
    ----------
    id : UUID
        Stable identifier of the reimbursement.
    advance_id : UUID
        The advance this reimbursement pays back.
    amount : int
        The amount paid back, a positive magnitude (cents).
    currency : str
        ISO 4217 code of ``amount`` (the advance's currency).
    transaction_id : UUID or None
        The linked incoming transaction, or ``None`` for a manual cash entry.
    participant_id : UUID or None
        The participant this reimbursement is attributed to (ADR 0012), or
        ``None`` for an unattributed one.
    note : str or None
        Optional free-text note.
    created_at : datetime
        When the reimbursement was recorded (timezone-aware, UTC).
    """

    id: UUID
    advance_id: UUID
    amount: int
    currency: str
    transaction_id: UUID | None
    participant_id: UUID | None
    note: str | None
    created_at: datetime

    @classmethod
    def from_domain(cls, reimbursement: Reimbursement) -> "ReimbursementResponse":
        """Project a domain :class:`~traccio.domain.models.Reimbursement`."""
        return cls(
            id=reimbursement.id,
            advance_id=reimbursement.advance_id,
            amount=reimbursement.amount.amount,
            currency=reimbursement.amount.currency,
            transaction_id=reimbursement.transaction_id,
            participant_id=reimbursement.participant_id,
            note=reimbursement.note,
            created_at=reimbursement.created_at,
        )


class ReimbursementsResponse(BaseModel):
    """Envelope for the reimbursements list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    reimbursements : list[ReimbursementResponse]
        The advance's reimbursements, oldest first.
    """

    reimbursements: list[ReimbursementResponse]
