"""Request and response schemas for the advance endpoints.

An advance records that the user paid for others on one outgoing transaction and
is owed money back. ``own_share`` is a positive magnitude (the cents the user
owes); ``receivable`` and ``outstanding`` are **derived** here from the domain
functions (:mod:`traccio.domain.advances`), never stored — the client renders
them and never recomputes.
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.advances import derive_advance
from traccio.domain.enums import AdvanceStatus
from traccio.domain.models import Advance, Participant, Transaction
from traccio.domain.money import Money


class ParticipantSchema(BaseModel):
    """One person who owes the user back, on the wire.

    Attributes
    ----------
    name : str
        The participant's plain name.
    expected_amount : int
        What the participant is expected to pay back, a positive magnitude in
        minor units (cents).
    """

    name: str
    expected_amount: int

    @classmethod
    def from_domain(cls, participant: Participant) -> "ParticipantSchema":
        """Project a domain :class:`~traccio.domain.models.Participant`."""
        return cls(name=participant.name, expected_amount=participant.expected_amount.amount)


class CreateAdvanceRequest(BaseModel):
    """Body for creating an advance on a transaction.

    Attributes
    ----------
    transaction_id : UUID
        The outgoing transaction to mark as an advance. Must be the caller's, a
        ``personal`` non-``rejected`` spend.
    own_share : int
        The part of the advance the user actually owes, a positive magnitude in
        the transaction's currency; ``0 <= own_share <= |amount|``.
    participants : list[ParticipantSchema]
        Optional people who owe the user back (may be empty).
    """

    transaction_id: UUID
    own_share: int
    participants: list[ParticipantSchema] = []


class AdvanceResponse(BaseModel):
    """One advance as returned to the client.

    Projects :class:`~traccio.domain.models.Advance` and adds the derived
    ``receivable``/``outstanding`` (positive magnitudes). The transaction carries
    ``role=advance``, so its ``effective_amount`` on ``GET /transactions`` is the
    user's share, not the full amount.

    Attributes
    ----------
    id : UUID
        Stable identifier of the advance.
    transaction_id : UUID
        The outgoing transaction this advance is on.
    own_share : int
        The user's declared share, a positive magnitude (cents).
    receivable : int
        What the user is owed: ``|amount| - own_share`` (positive magnitude).
    reimbursed : int
        The sum paid back so far, a positive magnitude.
    outstanding : int
        What is still owed after reimbursements, clamped at zero
        (``max(0, receivable - reimbursed)``).
    excess : int
        Over-reimbursement, ``max(0, reimbursed - receivable)`` — flagged for the
        user rather than silently absorbed. Zero in the normal case.
    currency : str
        ISO 4217 code of every amount here (the transaction's currency).
    status : AdvanceStatus
        Derived lifecycle state: ``written_off`` when written off, else
        ``settled`` once reimbursements cover the receivable, else ``open``.
    participants : list[ParticipantSchema]
        People who owe the user back.
    created_at : datetime
        When the advance was created (timezone-aware, UTC).
    """

    id: UUID
    transaction_id: UUID
    own_share: int
    receivable: int
    reimbursed: int
    outstanding: int
    excess: int
    currency: str
    status: AdvanceStatus
    participants: list[ParticipantSchema]
    created_at: datetime

    @classmethod
    def from_domain(
        cls,
        advance: Advance,
        transaction: Transaction,
        reimbursed: Money | None = None,
    ) -> "AdvanceResponse":
        """Project an :class:`~traccio.domain.models.Advance` with derived amounts.

        Derives ``receivable``/``reimbursed``/``outstanding``/``excess`` and the
        lifecycle ``status`` in one place via
        :func:`~traccio.domain.advances.derive_advance`. The stored ``status``
        only tells whether the advance was written off; ``settled`` is derived
        from the reimbursements (see ADR 0004).

        Parameters
        ----------
        advance : Advance
            The domain advance to project.
        transaction : Transaction
            Its outgoing transaction, needed to derive the receivable.
        reimbursed : Money or None, optional
            The sum reimbursed against this advance; defaults to zero in the
            advance's currency (no reimbursements).

        Returns
        -------
        AdvanceResponse
            The client-facing view of ``advance``.
        """
        currency = advance.own_share.currency
        reimbursed = reimbursed if reimbursed is not None else Money(amount=0, currency=currency)
        state = derive_advance(
            transaction,
            advance.own_share,
            reimbursed,
            written_off=advance.status is AdvanceStatus.WRITTEN_OFF,
        )
        return cls(
            id=advance.id,
            transaction_id=advance.transaction_id,
            own_share=advance.own_share.amount,
            receivable=state.receivable.amount,
            reimbursed=state.reimbursed.amount,
            outstanding=state.outstanding.amount,
            excess=state.excess.amount,
            currency=currency,
            status=state.status,
            participants=[ParticipantSchema.from_domain(p) for p in advance.participants],
            created_at=advance.created_at,
        )


class AdvancesResponse(BaseModel):
    """Envelope for the advances list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    advances : list[AdvanceResponse]
        The user's advances, oldest first.
    """

    advances: list[AdvanceResponse]
