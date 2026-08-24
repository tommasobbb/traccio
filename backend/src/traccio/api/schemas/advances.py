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

from traccio.domain.advances import ParticipantState, derive_advance
from traccio.domain.enums import AdvanceStatus, ParticipantStatus
from traccio.domain.models import Advance, Transaction
from traccio.domain.money import Money


class ParticipantRequest(BaseModel):
    """One person who owes the user back, as entered when creating an advance.

    No ``id``: the domain mints one on creation
    (:class:`~traccio.domain.models.Participant`'s own ``default_factory``) —
    the caller cannot know it yet. See :class:`ParticipantResponse` for the
    read side, which does carry one (ADR 0012).

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


class ParticipantResponse(BaseModel):
    """One person who owes the user back, as returned to the client.

    Adds a stable ``id`` and the derived reimbursement state (ADR 0012) on top
    of what :class:`ParticipantRequest` carries — split from a single shared
    schema because the request side genuinely has neither: the id doesn't
    exist yet, and there is nothing to derive over zero reimbursements.

    Attributes
    ----------
    id : UUID
        Stable identifier of the participant — what a reimbursement attributes
        itself to via ``participant_id``.
    name : str
        The participant's plain name.
    expected_amount : int
        What the participant is expected to pay back, a positive magnitude in
        minor units (cents).
    reimbursed : int
        The sum of reimbursements attributed to this participant, a positive
        magnitude.
    outstanding : int
        What this participant still owes, clamped at zero.
    excess : int
        Over-reimbursement for this participant specifically, clamped at zero
        — flagged, not absorbed, same as the advance-level ``excess``.
    status : ParticipantStatus
        ``settled`` once this participant's reimbursements cover their
        ``expected_amount``, else ``outstanding``.
    """

    id: UUID
    name: str
    expected_amount: int
    reimbursed: int
    outstanding: int
    excess: int
    status: ParticipantStatus

    @classmethod
    def from_domain(cls, state: ParticipantState) -> "ParticipantResponse":
        """Project a derived :class:`~traccio.domain.advances.ParticipantState`."""
        return cls(
            id=state.participant.id,
            name=state.participant.name,
            expected_amount=state.participant.expected_amount.amount,
            reimbursed=state.reimbursed.amount,
            outstanding=state.outstanding.amount,
            excess=state.excess.amount,
            status=state.status,
        )


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
    participants : list[ParticipantRequest]
        Optional people who owe the user back (may be empty).
    """

    transaction_id: UUID
    own_share: int
    participants: list[ParticipantRequest] = []


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
    participants : list[ParticipantResponse]
        People who owe the user back, each with their own derived
        reimbursement status (ADR 0012).
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
    participants: list[ParticipantResponse]
    created_at: datetime

    @classmethod
    def from_domain(
        cls,
        advance: Advance,
        transaction: Transaction,
        reimbursed: Money | None = None,
        *,
        participant_states: list[ParticipantState],
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
        participant_states : list[ParticipantState]
            Each participant's derived reimbursement state (ADR 0012), in the
            same order as ``advance.participants`` — the contract
            :func:`~traccio.domain.advances.derive_participant_states`
            guarantees. Keyword-only and required, not derived here: it needs
            the per-participant reimbursed sum, which the caller resolves
            once per request (or once per page of advances), never per
            advance — this schema only projects it. For a brand-new advance
            with no reimbursements yet, the caller still calls
            :func:`~traccio.domain.advances.derive_participant_states` with an
            empty reimbursed map (every participant comes back
            ``outstanding``), rather than this method inventing a second copy
            of that same derivation.

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
            participants=[ParticipantResponse.from_domain(s) for s in participant_states],
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
