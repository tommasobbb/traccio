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

from traccio.domain.advances import (
    AdvanceState,
    ParticipantState,
    PersonSummary,
    ReceivableTotal,
    derive_advance,
    person_key,
)
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
    person_key : str
        The cross-advance grouping key for ``name``
        (:func:`~traccio.domain.advances.person_key` — whitespace collapsed,
        case-folded). Lets the client tie a participant row to its
        :class:`PersonSummaryResponse` entry by an exact string compare
        instead of re-implementing the normalization (ADR 0026).
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
    person_key: str
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
            person_key=person_key(state.participant.name),
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
    description : str
        The transaction's raw bank description — so the Anticipi list can show
        *what* each advance was for without a per-id fetch.
    display_description : str or None
        The cleaned-up description when one exists, else ``None`` (same
        precedence the transaction read model uses).
    booked_at : datetime or None
        When the transaction was booked (timezone-aware, UTC), or ``None`` for
        a still-pending row.
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
    description: str
    display_description: str | None
    booked_at: datetime | None
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
        state: AdvanceState | None = None,
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
            Its outgoing transaction, needed to derive the receivable. Ignored
            when ``state`` is supplied.
        reimbursed : Money or None, optional
            The sum reimbursed against this advance; defaults to zero in the
            advance's currency (no reimbursements). Ignored when ``state`` is
            supplied.
        state : AdvanceState or None, optional
            A pre-computed :func:`~traccio.domain.advances.derive_advance`
            result. The list endpoint derives it once per advance to also feed
            the cross-advance roll-up (:class:`AdvancesSummaryResponse`), then
            hands it here so the derivation is not repeated. When ``None`` this
            method derives it from ``transaction`` and ``reimbursed``.
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
        if state is None:
            reimbursed = (
                reimbursed if reimbursed is not None else Money(amount=0, currency=currency)
            )
            state = derive_advance(
                transaction,
                advance.own_share,
                reimbursed,
                written_off=advance.status is AdvanceStatus.WRITTEN_OFF,
            )
        return cls(
            id=advance.id,
            transaction_id=advance.transaction_id,
            description=transaction.description,
            display_description=transaction.display_description,
            booked_at=transaction.booked_at,
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


class PersonSummaryResponse(BaseModel):
    """One person's receivable rolled up across every advance they appear on.

    Names are matched loosely (case- and whitespace-insensitive); there is no
    person entity, so ``"Marco"`` and ``" marco "`` are the same person but a
    real typo is not (ADR 0026). All amounts are positive magnitudes in
    ``currency``.

    Attributes
    ----------
    name : str
        Display spelling — the first one seen for this person.
    person_key : str
        The grouping key this row was rolled up under
        (:func:`~traccio.domain.advances.person_key`). The client matches a
        :class:`ParticipantResponse` to this row on this exact string.
    currency : str
        ISO 4217 code of every amount here.
    expected : int
        Sum of this person's expected repayments (cents).
    reimbursed : int
        Sum attributed back to this person (cents).
    outstanding : int
        What this person still owes in total (cents), each advance clamped at
        zero before summing.
    advance_count : int
        How many advances this person appears on.
    """

    name: str
    person_key: str
    currency: str
    expected: int
    reimbursed: int
    outstanding: int
    advance_count: int

    @classmethod
    def from_domain(cls, summary: PersonSummary) -> "PersonSummaryResponse":
        """Project a :class:`~traccio.domain.advances.PersonSummary`."""
        return cls(
            name=summary.name,
            person_key=person_key(summary.name),
            currency=summary.currency,
            expected=summary.expected.amount,
            reimbursed=summary.reimbursed.amount,
            outstanding=summary.outstanding.amount,
            advance_count=summary.advance_count,
        )


class ReceivableTotalResponse(BaseModel):
    """What the user is still owed in one currency, across all advances.

    Attributes
    ----------
    currency : str
        ISO 4217 code.
    outstanding : int
        Total still owed (cents). Can exceed the sum of the per-person
        outstandings when some reimbursements are not attributed to a
        participant.
    open_advances : int
        Count of still-open advances in this currency.
    """

    currency: str
    outstanding: int
    open_advances: int

    @classmethod
    def from_domain(cls, total: ReceivableTotal) -> "ReceivableTotalResponse":
        """Project a :class:`~traccio.domain.advances.ReceivableTotal`."""
        return cls(
            currency=total.currency,
            outstanding=total.outstanding.amount,
            open_advances=total.open_advances,
        )


class AdvancesSummaryResponse(BaseModel):
    """Cross-advance roll-ups: who owes the user, and how much in total.

    Derived over *every* advance regardless of any ``status`` filter applied to
    the list — the totals answer "how much am I owed" and must not shift when
    the client narrows the visible rows.

    Attributes
    ----------
    by_person : list[PersonSummaryResponse]
        One entry per person, most owed first.
    totals : list[ReceivableTotalResponse]
        One entry per currency, ordered by currency code.
    """

    by_person: list[PersonSummaryResponse]
    totals: list[ReceivableTotalResponse]

    @classmethod
    def from_domain(
        cls,
        *,
        by_person: list[PersonSummary],
        totals: list[ReceivableTotal],
    ) -> "AdvancesSummaryResponse":
        """Project the domain roll-ups."""
        return cls(
            by_person=[PersonSummaryResponse.from_domain(p) for p in by_person],
            totals=[ReceivableTotalResponse.from_domain(t) for t in totals],
        )


class AdvancesResponse(BaseModel):
    """Envelope for the advances list.

    A wrapper object rather than a bare array carries the cross-advance
    ``summary`` alongside the rows without a second round trip.

    Attributes
    ----------
    advances : list[AdvanceResponse]
        The user's advances, oldest first — narrowed by the ``status`` query
        parameter when one is given.
    summary : AdvancesSummaryResponse
        Roll-ups over every advance, unaffected by the ``status`` filter.
    """

    advances: list[AdvanceResponse]
    summary: AdvancesSummaryResponse
