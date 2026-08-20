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

from traccio.domain.advances import outstanding, receivable
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
    outstanding : int
        What is still owed after reimbursements. Equals ``receivable`` until the
        reimbursement work lands.
    currency : str
        ISO 4217 code of every amount here (the transaction's currency).
    status : AdvanceStatus
        Lifecycle state; ``open`` when created.
    participants : list[ParticipantSchema]
        People who owe the user back.
    created_at : datetime
        When the advance was created (timezone-aware, UTC).
    """

    id: UUID
    transaction_id: UUID
    own_share: int
    receivable: int
    outstanding: int
    currency: str
    status: AdvanceStatus
    participants: list[ParticipantSchema]
    created_at: datetime

    @classmethod
    def from_domain(cls, advance: Advance, transaction: Transaction) -> "AdvanceResponse":
        """Project an :class:`~traccio.domain.models.Advance` with derived amounts.

        Derives ``receivable``/``outstanding`` in one place via the pure domain
        functions. No reimbursements exist yet, so ``outstanding == receivable``.

        Parameters
        ----------
        advance : Advance
            The domain advance to project.
        transaction : Transaction
            Its outgoing transaction, needed to derive the receivable.

        Returns
        -------
        AdvanceResponse
            The client-facing view of ``advance``.
        """
        currency = advance.own_share.currency
        receivable_amount = receivable(transaction, advance.own_share)
        outstanding_amount = outstanding(receivable_amount, Money(amount=0, currency=currency))
        return cls(
            id=advance.id,
            transaction_id=advance.transaction_id,
            own_share=advance.own_share.amount,
            receivable=receivable_amount.amount,
            outstanding=outstanding_amount.amount,
            currency=currency,
            status=advance.status,
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
